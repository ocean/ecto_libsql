defmodule EctoLibSqlSmokeTest do
  @moduledoc """
  Basic smoke tests for EctoLibSql.

  These are minimal sanity checks to verify core functionality works.
  More comprehensive tests are in specialized test files:
  - prepared_statement_test.exs - Prepared statements
  - vector_geospatial_test.exs - Vector and R*Tree features
  - savepoint_test.exs - Transactions and savepoints
  - ecto_migration_test.exs - Migrations
  """
  use ExUnit.Case
  doctest EctoLibSql

  setup_all do
    # Clean up any existing test database from previous runs
    File.rm("z_ecto_libsql_test-smoke.db")
    File.rm("z_ecto_libsql_test-smoke.db-shm")
    File.rm("z_ecto_libsql_test-smoke.db-wal")

    on_exit(fn ->
      # Clean up at end of all tests too
      File.rm("z_ecto_libsql_test-smoke.db")
      File.rm("z_ecto_libsql_test-smoke.db-shm")
      File.rm("z_ecto_libsql_test-smoke.db-wal")
    end)

    :ok
  end

  setup do
    # Create a unique database file for each test to ensure isolation
    test_db = "z_ecto_libsql_test-#{:erlang.unique_integer([:positive])}.db"

    opts = [
      uri: System.get_env("LIBSQL_URI"),
      auth_token: System.get_env("LIBSQL_TOKEN"),
      database: test_db,
      sync: true
    ]

    # Clean up database file after test completes
    on_exit(fn ->
      File.rm(test_db)
      File.rm(test_db <> "-shm")
      File.rm(test_db <> "-wal")
    end)

    {:ok, opts: opts}
  end

  describe "basic connectivity" do
    test "can connect to database", state do
      assert {:ok, _state} = EctoLibSql.connect(state[:opts])
    end

    test "can ping connection", state do
      {:ok, conn} = EctoLibSql.connect(state[:opts])
      assert {:ok, _ping_state} = EctoLibSql.ping(conn)
    end

    test "can disconnect", state do
      {:ok, conn} = EctoLibSql.connect(state[:opts])
      assert :ok = EctoLibSql.disconnect([], conn)
    end
  end

  describe "basic queries" do
    test "can execute a simple select", state do
      {:ok, state} = EctoLibSql.connect(state[:opts])
      query = %EctoLibSql.Query{statement: "SELECT 1 + 1"}
      assert {:ok, _query, _result, _state} = EctoLibSql.handle_execute(query, [], [], state)
    end

    test "handles invalid SQL with error", state do
      {:ok, state} = EctoLibSql.connect(state[:opts])
      query = %EctoLibSql.Query{statement: "SELECT * FROM not_existing_table"}
      assert {:error, %EctoLibSql.Error{}, _state} = EctoLibSql.handle_execute(query, [], [], state)
    end

    test "can execute multiple statements", state do
      {:ok, state} = EctoLibSql.connect(state[:opts])

      # Create table first
      create_table = %EctoLibSql.Query{
        statement:
          "CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, email TEXT)"
      }

      {:ok, _query, _result, state} = EctoLibSql.handle_execute(create_table, [], [], state)

      # Multiple statements in one execution
      multi_stmt = %EctoLibSql.Query{
        statement: """
        INSERT INTO users (name, email) VALUES ('test', 'test@mail.com');
        SELECT * FROM users WHERE name = 'test';
        """
      }

      assert {:ok, _query, _result, _state} = EctoLibSql.handle_execute(multi_stmt, [], [], state)
    end
  end

  describe "basic transaction" do
    test "can begin, execute, and commit", state do
      {:ok, state} = EctoLibSql.connect(state[:opts])

      # Create table first
      create = %EctoLibSql.Query{
        statement:
          "CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, email TEXT)"
      }

      {:ok, _query, _result, state} = EctoLibSql.handle_execute(create, [], [], state)

      # Begin transaction
      {:ok, _begin_result, state} = EctoLibSql.handle_begin([], state)

      # Insert data
      insert = %EctoLibSql.Query{statement: "INSERT INTO users (name, email) VALUES (?, ?)"}
      {:ok, _query, _result, state} = EctoLibSql.handle_execute(insert, ["Alice", "alice@example.com"], [], state)

      # Commit
      assert {:ok, _commit_result, _state} = EctoLibSql.handle_commit([], state)
    end
  end
end
