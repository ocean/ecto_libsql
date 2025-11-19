defmodule Ecto.Adapters.EctoLibSqlTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.EctoLibSql

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
      assert :ok == EctoLibSql.storage_up(opts)
      assert File.exists?(@test_db)
    end

    test "storage_up returns error if database already exists" do
      opts = [database: @test_db]
      EctoLibSql.storage_up(opts)
      assert {:error, :already_up} == EctoLibSql.storage_up(opts)
    end

    test "storage_down removes the database file" do
      opts = [database: @test_db]
      EctoLibSql.storage_up(opts)
      assert :ok == EctoLibSql.storage_down(opts)
      refute File.exists?(@test_db)
    end

    test "storage_down returns error if database doesn't exist" do
      opts = [database: @test_db]
      assert {:error, :already_down} == EctoLibSql.storage_down(opts)
    end

    test "storage_status returns :up if database exists" do
      opts = [database: @test_db]
      EctoLibSql.storage_up(opts)
      assert :up == EctoLibSql.storage_status(opts)
    end

    test "storage_status returns :down if database doesn't exist" do
      opts = [database: @test_db]
      assert :down == EctoLibSql.storage_status(opts)
    end
  end

  describe "remote-only mode" do
    test "storage_up returns error for remote-only mode" do
      opts = [uri: "libsql://example.turso.io", auth_token: "token"]
      assert {:error, :already_up} == EctoLibSql.storage_up(opts)
    end

    test "storage_down returns error for remote-only mode" do
      opts = [uri: "libsql://example.turso.io", auth_token: "token"]
      assert {:error, :not_supported} == EctoLibSql.storage_down(opts)
    end

    test "storage_status returns :up for remote-only mode" do
      opts = [uri: "libsql://example.turso.io", auth_token: "token"]
      assert :up == EctoLibSql.storage_status(opts)
    end
  end

  describe "type loaders" do
    test "loads boolean values correctly" do
      assert {:ok, false} == EctoLibSql.loaders(:boolean, :boolean) |> List.first() |> apply([0])
      assert {:ok, true} == EctoLibSql.loaders(:boolean, :boolean) |> List.first() |> apply([1])
    end

    test "loads datetime from string" do
      loader = EctoLibSql.loaders(:naive_datetime, :naive_datetime) |> List.first()
      {:ok, dt} = loader.("2024-01-15T10:30:00")
      assert %NaiveDateTime{} = dt
      assert dt.year == 2024
      assert dt.month == 1
      assert dt.day == 15
    end

    test "loads date from string" do
      loader = EctoLibSql.loaders(:date, :date) |> List.first()
      {:ok, date} = loader.("2024-01-15")
      assert %Date{} = date
      assert date.year == 2024
      assert date.month == 1
      assert date.day == 15
    end

    test "loads time from string" do
      loader = EctoLibSql.loaders(:time, :time) |> List.first()
      {:ok, time} = loader.("10:30:00")
      assert %Time{} = time
      assert time.hour == 10
      assert time.minute == 30
    end
  end

  describe "type dumpers" do
    test "dumps boolean to integer" do
      dumper = EctoLibSql.dumpers(:boolean, :boolean) |> List.last()
      assert {:ok, 0} == dumper.(false)
      assert {:ok, 1} == dumper.(true)
    end

    test "dumps datetime to string" do
      dumper = EctoLibSql.dumpers(:naive_datetime, :naive_datetime) |> List.last()
      dt = ~N[2024-01-15 10:30:00]
      {:ok, result} = dumper.(dt)
      assert is_binary(result)
      assert result == "2024-01-15T10:30:00"
    end

    test "dumps date to string" do
      dumper = EctoLibSql.dumpers(:date, :date) |> List.last()
      date = ~D[2024-01-15]
      {:ok, result} = dumper.(date)
      assert result == "2024-01-15"
    end

    test "dumps time to string" do
      dumper = EctoLibSql.dumpers(:time, :time) |> List.last()
      time = ~T[10:30:00]
      {:ok, result} = dumper.(time)
      assert result == "10:30:00"
    end

    test "dumps binary with blob wrapper" do
      dumper = EctoLibSql.dumpers(:binary, :binary) |> List.last()
      {:ok, result} = dumper.(<<1, 2, 3>>)
      assert {:blob, <<1, 2, 3>>} == result
    end
  end
end
