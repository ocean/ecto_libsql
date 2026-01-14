defmodule EctoLibSql.EctoReturningSharedSchemaTest do
  @moduledoc """
  Debug test comparing standalone schema vs shared schema for RETURNING
  """

  use ExUnit.Case, async: false

  defmodule LocalTestRepo do
    use Ecto.Repo, otp_app: :ecto_libsql, adapter: Ecto.Adapters.LibSql
  end

  alias EctoLibSql.Schemas.User  # Using shared schema

  @test_db "z_ecto_libsql_test-shared_schema_returning.db"

  setup_all do
    {:ok, _} = LocalTestRepo.start_link(database: @test_db)

    # Create table using the same migration approach as ecto_returning_test
    Ecto.Adapters.SQL.query!(LocalTestRepo, """
    CREATE TABLE IF NOT EXISTS users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      custom_id TEXT,
      inserted_at DATETIME,
      updated_at DATETIME
    )
    """)

    on_exit(fn ->
      EctoLibSql.TestHelpers.cleanup_db_files(@test_db)
    end)

    :ok
  end

  test "insert shared schema user and get ID back" do
    IO.puts("\n=== Testing Shared Schema Insert RETURNING ===")
    
    result = LocalTestRepo.insert(%User{name: "Alice"})
    IO.inspect(result, label: "Insert result")

    case result do
      {:ok, user} ->
        IO.inspect(user, label: "User struct")
        assert user.id != nil, "User ID should not be nil (got: #{inspect(user.id)})"
        assert user.name == "Alice"

      {:error, reason} ->
        flunk("Insert failed: #{inspect(reason)}")
    end
  end
end
