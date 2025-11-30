defmodule Ecto.Adapters.LibSqlTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.LibSql

  @test_db "test_ecto_adapter.db"

  setup do
    # Clean up any existing test database
    File.rm(@test_db)
    on_exit(fn -> File.rm(@test_db) end)
    :ok
  end

  describe "storage operations" do
    test "storage_up creates a new database file" do
      opts = [database: @test_db]
      assert :ok == LibSql.storage_up(opts)
      assert File.exists?(@test_db)
    end

    test "storage_up returns error if database already exists" do
      opts = [database: @test_db]
      LibSql.storage_up(opts)
      assert {:error, :already_up} == LibSql.storage_up(opts)
    end

    test "storage_down removes the database file" do
      opts = [database: @test_db]
      LibSql.storage_up(opts)
      assert :ok == LibSql.storage_down(opts)
      refute File.exists?(@test_db)
    end

    test "storage_down returns error if database doesn't exist" do
      opts = [database: @test_db]
      assert {:error, :already_down} == LibSql.storage_down(opts)
    end

    test "storage_status returns :up if database exists" do
      opts = [database: @test_db]
      LibSql.storage_up(opts)
      assert :up == LibSql.storage_status(opts)
    end

    test "storage_status returns :down if database doesn't exist" do
      opts = [database: @test_db]
      assert :down == LibSql.storage_status(opts)
    end
  end

  describe "remote-only mode" do
    test "storage_up returns error for remote-only mode" do
      opts = [uri: "libsql://example.turso.io", auth_token: "token"]
      assert {:error, :already_up} == LibSql.storage_up(opts)
    end

    test "storage_down returns error for remote-only mode" do
      opts = [uri: "libsql://example.turso.io", auth_token: "token"]
      assert {:error, :not_supported} == LibSql.storage_down(opts)
    end

    test "storage_status returns :up for remote-only mode" do
      opts = [uri: "libsql://example.turso.io", auth_token: "token"]
      assert :up == LibSql.storage_status(opts)
    end
  end

  describe "type loaders" do
    test "loads boolean values correctly" do
      assert {:ok, false} == LibSql.loaders(:boolean, :boolean) |> List.first() |> apply([0])
      assert {:ok, true} == LibSql.loaders(:boolean, :boolean) |> List.first() |> apply([1])
    end

    test "loads datetime from string" do
      loader = LibSql.loaders(:naive_datetime, :naive_datetime) |> List.first()
      {:ok, dt} = loader.("2024-01-15T10:30:00")
      assert %NaiveDateTime{} = dt
      assert dt.year == 2024
      assert dt.month == 1
      assert dt.day == 15
    end

    test "loads date from string" do
      loader = LibSql.loaders(:date, :date) |> List.first()
      {:ok, date} = loader.("2024-01-15")
      assert %Date{} = date
      assert date.year == 2024
      assert date.month == 1
      assert date.day == 15
    end

    test "loads time from string" do
      loader = LibSql.loaders(:time, :time) |> List.first()
      {:ok, time} = loader.("10:30:00")
      assert %Time{} = time
      assert time.hour == 10
      assert time.minute == 30
    end
  end

  describe "type dumpers" do
    test "dumps boolean to integer" do
      dumper = LibSql.dumpers(:boolean, :boolean) |> List.last()
      assert {:ok, 0} == dumper.(false)
      assert {:ok, 1} == dumper.(true)
    end

    test "dumps datetime to string" do
      dumper = LibSql.dumpers(:naive_datetime, :naive_datetime) |> List.last()
      dt = ~N[2024-01-15 10:30:00]
      {:ok, result} = dumper.(dt)
      assert is_binary(result)
      assert result == "2024-01-15T10:30:00"
    end

    test "dumps date to string" do
      dumper = LibSql.dumpers(:date, :date) |> List.last()
      date = ~D[2024-01-15]
      {:ok, result} = dumper.(date)
      assert result == "2024-01-15"
    end

    test "dumps time to string" do
      dumper = LibSql.dumpers(:time, :time) |> List.last()
      time = ~T[10:30:00]
      {:ok, result} = dumper.(time)
      assert result == "10:30:00"
    end

    test "dumps binary as-is (no wrapper needed)" do
      dumpers = LibSql.dumpers(:binary, :binary)
      # Should just be [type] - binary passes through directly to Rust
      assert dumpers == [:binary]
    end
  end

  describe "autogenerate" do
    test "autogenerate(:id) returns nil" do
      assert LibSql.autogenerate(:id) == nil
    end

    test "autogenerate(:binary_id) returns a string UUID" do
      uuid = LibSql.autogenerate(:binary_id)
      assert is_binary(uuid)
      # String UUIDs are 36 characters (with hyphens)
      assert String.length(uuid) == 36
      # Verify it's a valid UUID format
      assert uuid =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
    end

    test "autogenerate(:embed_id) returns a string UUID" do
      uuid = LibSql.autogenerate(:embed_id)
      assert is_binary(uuid)
      assert String.length(uuid) == 36
      assert uuid =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
    end
  end
end
