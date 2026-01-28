defmodule EctoLibSql.EctoSqlite3BlobCompatTest do
  @moduledoc """
  Compatibility tests based on ecto_sqlite3 blob test suite.

  These tests ensure that binary/blob field handling works identically to ecto_sqlite3.
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias EctoLibSql.Schemas.Setting

  defmodule TestRepo do
    use Ecto.Repo, otp_app: :ecto_libsql, adapter: Ecto.Adapters.LibSql
  end

  @test_db "z_ecto_libsql_test-sqlite3_blob_compat.db"

  setup_all do
    # Clean up any existing test database
    EctoLibSql.TestHelpers.cleanup_db_files(@test_db)

    # Configure the repo
    Application.put_env(:ecto_libsql, TestRepo,
      adapter: Ecto.Adapters.LibSql,
      database: @test_db
    )

    {:ok, _} = TestRepo.start_link()

    # Create tables manually
    SQL.query!(TestRepo, """
    CREATE TABLE IF NOT EXISTS settings (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      properties TEXT,
      checksum BLOB
    )
    """)

    on_exit(fn ->
      EctoLibSql.TestHelpers.cleanup_db_files(@test_db)
    end)

    :ok
  end

  setup do
    # Clear all tables before each test for proper isolation
    SQL.query!(TestRepo, "DELETE FROM settings", [])
    :ok
  end

  @tag :skip
  test "updates blob to nil" do
    setting =
      %Setting{}
      |> Setting.changeset(%{checksum: <<0x00, 0x01>>})
      |> TestRepo.insert!()

    # Read the record back using ecto and confirm it
    assert %Setting{checksum: <<0x00, 0x01>>} =
             TestRepo.get(Setting, setting.id)

    assert %Setting{checksum: nil} =
             setting
             |> Setting.changeset(%{checksum: nil})
             |> TestRepo.update!()
  end

  test "inserts and retrieves binary data" do
    binary_data = <<1, 2, 3, 4, 5, 255>>

    setting =
      %Setting{}
      |> Setting.changeset(%{checksum: binary_data})
      |> TestRepo.insert!()

    fetched = TestRepo.get(Setting, setting.id)
    IO.inspect(fetched.checksum, label: "fetched checksum")
    IO.inspect(binary_data, label: "expected checksum")
    assert fetched.checksum == binary_data
  end

  test "binary data round-trip with various byte values" do
    # Test with various byte values including edge cases
    binary_data = <<0x00, 0x7F, 0x80, 0xFF, 1, 2, 3>>

    setting =
      %Setting{}
      |> Setting.changeset(%{checksum: binary_data})
      |> TestRepo.insert!()

    fetched = TestRepo.get(Setting, setting.id)
    assert fetched.checksum == binary_data
    assert byte_size(fetched.checksum) == byte_size(binary_data)
  end

  test "updates binary field to new value" do
    original = <<0xAA, 0xBB>>

    setting =
      %Setting{}
      |> Setting.changeset(%{checksum: original})
      |> TestRepo.insert!()

    new_value = <<0x11, 0x22, 0x33>>

    {:ok, updated} =
      setting
      |> Setting.changeset(%{checksum: new_value})
      |> TestRepo.update()

    fetched = TestRepo.get(Setting, updated.id)
    assert fetched.checksum == new_value
  end
end
