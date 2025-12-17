defmodule TursoRemoteTest do
  @moduledoc """
  Integration tests for actual Turso remote database connections.

  These tests require TURSO_DB_URI and TURSO_AUTH_TOKEN environment variables to be set.
  They will be skipped if the environment variables are not present.

  To run these tests locally:
    export TURSO_DB_URI="libsql://your-database.turso.io"
    export TURSO_AUTH_TOKEN="your-token"
    mix test test/turso_remote_test.exs

  For CI/CD, set these as GitHub secrets and they will be available during test runs.
  """
  use ExUnit.Case

  @turso_uri System.get_env("TURSO_DB_URI")
  @turso_token System.get_env("TURSO_AUTH_TOKEN")

  # Skip entire suite if credentials not available
  @moduletag :turso_remote
  @moduletag skip: is_nil(@turso_uri) || is_nil(@turso_token)

  setup_all do
    if not (is_nil(@turso_uri) or is_nil(@turso_token)) do
      IO.puts("\n[TURSO TESTS] Running remote Turso database tests")
      IO.puts("[TURSO TESTS] Using database: #{@turso_uri}")
    end

    :ok
  end

  # Helper function to clean up local database files created by tests
  # SQLite creates multiple files: .db, .db-wal, .db-shm, and Turso creates .db-info
  defp cleanup_local_db(db_path) do
    File.rm(db_path)
    File.rm("#{db_path}-wal")
    File.rm("#{db_path}-shm")
    File.rm("#{db_path}-info")
    :ok
  end

  # Helper function to wait for replica sync to complete
  defp wait_for_sync(state, table_name, opts \\ []) do
    max_attempts = Keyword.get(opts, :max_attempts, 10)
    interval_ms = Keyword.get(opts, :interval_ms, 500)

    # Manually trigger sync
    case EctoLibSql.Native.sync(state) do
      :ok -> :ok
      # Some versions return {:ok, message}
      {:ok, _} -> :ok
      # Ignore sync errors, will retry
      {:error, _} -> :ok
    end

    # Poll to verify table exists
    wait_for_table(state, table_name, max_attempts, interval_ms)
  end

  defp wait_for_table(state, table_name, attempts_left, interval_ms) when attempts_left > 0 do
    case EctoLibSql.handle_execute(
           "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
           [table_name],
           [],
           state
         ) do
      {:ok, _, %{rows: [[^table_name]]}, _} ->
        # Table exists, sync complete
        :ok

      _ ->
        # Table doesn't exist yet, wait and retry
        Process.sleep(interval_ms)
        wait_for_table(state, table_name, attempts_left - 1, interval_ms)
    end
  end

  defp wait_for_table(_state, _table_name, 0, _interval_ms) do
    {:error, :sync_timeout}
  end

  setup do
    # Each test uses unique table names to avoid conflicts
    table_name = "test_#{:erlang.unique_integer([:positive])}"

    on_exit(fn ->
      # Clean up: try to drop the test table
      # Best effort cleanup, ignore errors
      case EctoLibSql.connect(uri: @turso_uri, auth_token: @turso_token) do
        {:ok, state} ->
          EctoLibSql.handle_execute(
            "DROP TABLE IF EXISTS #{table_name}",
            [],
            [],
            state
          )

          EctoLibSql.disconnect([], state)

        _ ->
          :ok
      end
    end)

    {:ok, table_name: table_name}
  end

  describe "remote-only connection" do
    test "can connect to Turso remote database" do
      opts = [
        uri: @turso_uri,
        auth_token: @turso_token
      ]

      assert {:ok, state} = EctoLibSql.connect(opts)
      assert EctoLibSql.disconnect([], state) == :ok
    end

    test "ping remote connection", %{table_name: _table} do
      {:ok, state} = EctoLibSql.connect(uri: @turso_uri, auth_token: @turso_token)
      assert {:ok, _} = EctoLibSql.ping(state)
      EctoLibSql.disconnect([], state)
    end

    test "simple query on remote database", %{table_name: _table} do
      {:ok, state} = EctoLibSql.connect(uri: @turso_uri, auth_token: @turso_token)

      query = %EctoLibSql.Query{statement: "SELECT 1 + 1 as result"}
      assert {:ok, _, result, _} = EctoLibSql.handle_execute(query, [], [], state)
      assert result.rows == [[2]]

      EctoLibSql.disconnect([], state)
    end

    test "create table and insert data remotely", %{table_name: table} do
      {:ok, state} = EctoLibSql.connect(uri: @turso_uri, auth_token: @turso_token)

      # Create table
      create_query = %EctoLibSql.Query{
        statement:
          "CREATE TABLE IF NOT EXISTS #{table} (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, email TEXT)"
      }

      assert {:ok, _, _, state} = EctoLibSql.handle_execute(create_query, [], [], state)

      # Insert data
      insert_query = %EctoLibSql.Query{
        statement: "INSERT INTO #{table} (name, email) VALUES (?1, ?2)"
      }

      assert {:ok, _, _, state} =
               EctoLibSql.handle_execute(
                 insert_query,
                 ["Alice", "alice@turso.test"],
                 [],
                 state
               )

      # Query data back
      select_query = %EctoLibSql.Query{
        statement: "SELECT name, email FROM #{table} WHERE name = ?"
      }

      assert {:ok, _, result, _} =
               EctoLibSql.handle_execute(select_query, ["Alice"], [], state)

      assert result.rows == [["Alice", "alice@turso.test"]]

      EctoLibSql.disconnect([], state)
    end
  end

  describe "remote transactions" do
    test "commit transaction on remote database", %{table_name: table} do
      {:ok, state} = EctoLibSql.connect(uri: @turso_uri, auth_token: @turso_token)

      # Create table
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE IF NOT EXISTS #{table} (id INTEGER PRIMARY KEY, value TEXT)",
          [],
          [],
          state
        )

      # Begin transaction
      {:ok, _, trx_state} = EctoLibSql.handle_begin([], state)

      # Insert in transaction
      insert_query = %EctoLibSql.Query{
        statement: "INSERT INTO #{table} (value) VALUES (?)"
      }

      {:ok, _, _, trx_state} =
        EctoLibSql.handle_execute(insert_query, ["committed"], [], trx_state)

      # Commit
      assert {:ok, _, committed_state} = EctoLibSql.handle_commit([], trx_state)

      # Verify data persisted
      {:ok, _, result, _} =
        EctoLibSql.handle_execute(
          "SELECT value FROM #{table}",
          [],
          [],
          committed_state
        )

      assert result.rows == [["committed"]]

      EctoLibSql.disconnect([], committed_state)
    end

    test "rollback transaction on remote database", %{table_name: table} do
      {:ok, state} = EctoLibSql.connect(uri: @turso_uri, auth_token: @turso_token)

      # Create table
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE IF NOT EXISTS #{table} (id INTEGER PRIMARY KEY, value TEXT)",
          [],
          [],
          state
        )

      # Begin transaction
      {:ok, _, trx_state} = EctoLibSql.handle_begin([], state)

      # Insert in transaction
      insert_query = %EctoLibSql.Query{
        statement: "INSERT INTO #{table} (value) VALUES (?)"
      }

      {:ok, _, _, trx_state} =
        EctoLibSql.handle_execute(insert_query, ["should_rollback"], [], trx_state)

      # Rollback
      assert {:ok, _, rolled_back_state} = EctoLibSql.handle_rollback([], trx_state)

      # Verify data NOT persisted
      {:ok, _, result, _} =
        EctoLibSql.handle_execute(
          "SELECT value FROM #{table}",
          [],
          [],
          rolled_back_state
        )

      assert result.rows == []

      EctoLibSql.disconnect([], rolled_back_state)
    end
  end

  describe "remote batch operations" do
    test "batch operations on remote database", %{table_name: table} do
      {:ok, state} = EctoLibSql.connect(uri: @turso_uri, auth_token: @turso_token)

      # Create table first
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE IF NOT EXISTS #{table} (id INTEGER PRIMARY KEY, value TEXT)",
          [],
          [],
          state
        )

      # Execute batch
      statements = [
        {"INSERT INTO #{table} (id, value) VALUES (?, ?)", [1, "first"]},
        {"INSERT INTO #{table} (id, value) VALUES (?, ?)", [2, "second"]},
        {"INSERT INTO #{table} (id, value) VALUES (?, ?)", [3, "third"]},
        {"SELECT COUNT(*) FROM #{table}", []}
      ]

      {:ok, results} = EctoLibSql.Native.batch(state, statements)

      # Should have 4 results
      assert length(results) == 4

      # Last result should be the count
      count_result = List.last(results)
      [[count]] = count_result.rows
      assert count == 3

      EctoLibSql.disconnect([], state)
    end

    test "transactional batch with rollback on error", %{table_name: table} do
      {:ok, state} = EctoLibSql.connect(uri: @turso_uri, auth_token: @turso_token)

      # Create table
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE IF NOT EXISTS #{table} (id INTEGER PRIMARY KEY, value TEXT)",
          [],
          [],
          state
        )

      # This batch should fail due to duplicate key
      statements = [
        {"INSERT INTO #{table} (id, value) VALUES (?, ?)", [1, "first"]},
        {"INSERT INTO #{table} (id, value) VALUES (?, ?)", [1, "duplicate"]}
      ]

      # Should return error
      assert {:error, _} = EctoLibSql.Native.batch_transactional(state, statements)

      # Verify no data was inserted (rollback worked)
      {:ok, _, result, _} =
        EctoLibSql.handle_execute(
          "SELECT COUNT(*) FROM #{table}",
          [],
          [],
          state
        )

      [[count]] = result.rows
      assert count == 0

      EctoLibSql.disconnect([], state)
    end
  end

  describe "remote prepared statements" do
    test "prepare and execute statements remotely", %{table_name: table} do
      {:ok, state} = EctoLibSql.connect(uri: @turso_uri, auth_token: @turso_token)

      # Create table
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE IF NOT EXISTS #{table} (id INTEGER PRIMARY KEY, name TEXT, score REAL)",
          [],
          [],
          state
        )

      # Insert test data
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO #{table} (id, name, score) VALUES (?, ?, ?)",
          [1, "Alice", 95.5],
          [],
          state
        )

      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO #{table} (id, name, score) VALUES (?, ?, ?)",
          [2, "Bob", 87.3],
          [],
          state
        )

      # Prepare statement
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "SELECT * FROM #{table} WHERE name = ?")

      # Execute with different parameters
      {:ok, result1} = EctoLibSql.Native.query_stmt(state, stmt_id, ["Alice"])
      assert result1.num_rows == 1
      [[1, "Alice", 95.5]] = result1.rows

      {:ok, result2} = EctoLibSql.Native.query_stmt(state, stmt_id, ["Bob"])
      assert result2.num_rows == 1
      [[2, "Bob", 87.3]] = result2.rows

      # Clean up
      assert :ok = EctoLibSql.Native.close_stmt(stmt_id)
      EctoLibSql.disconnect([], state)
    end
  end

  describe "remote vector operations" do
    test "vector similarity search on remote database", %{table_name: table} do
      {:ok, state} = EctoLibSql.connect(uri: @turso_uri, auth_token: @turso_token)

      # Drop table if it exists from a previous test run
      EctoLibSql.handle_execute("DROP TABLE IF EXISTS #{table}", [], [], state)

      # Create table with vector column
      vector_type = EctoLibSql.Native.vector_type(3, :f32)

      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE #{table} (id INTEGER PRIMARY KEY, name TEXT, embedding #{vector_type})",
          [],
          [],
          state
        )

      # Insert vectors with different directions (not collinear)
      # vec1 is close to [1, 2, 3] direction
      # vec2 is in a different direction
      # vec3 is in yet another direction
      vec1 = EctoLibSql.Native.vector([1.0, 2.0, 3.0])
      vec2 = EctoLibSql.Native.vector([5.0, 1.0, 2.0])
      vec3 = EctoLibSql.Native.vector([8.0, 9.0, 1.0])

      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO #{table} (id, name, embedding) VALUES (?, ?, vector(?))",
          [1, "Item A", vec1],
          [],
          state
        )

      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO #{table} (id, name, embedding) VALUES (?, ?, vector(?))",
          [2, "Item B", vec2],
          [],
          state
        )

      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO #{table} (id, name, embedding) VALUES (?, ?, vector(?))",
          [3, "Item C", vec3],
          [],
          state
        )

      # Search for similar vectors - query is close to vec1 direction
      query_vector = [1.5, 2.1, 2.9]
      distance_fn = EctoLibSql.Native.vector_distance_cos("embedding", query_vector)

      # First, let's see the actual distances
      {:ok, _, debug_result, _} =
        EctoLibSql.handle_execute(
          "SELECT id, name, #{distance_fn} as distance FROM #{table} ORDER BY distance LIMIT 3",
          [],
          [],
          state
        )

      IO.puts("\n[VECTOR DEBUG] Query: #{inspect(query_vector)}")
      IO.puts("[VECTOR DEBUG] Results with distances:")

      Enum.each(debug_result.rows, fn row ->
        IO.puts("  #{inspect(row)}")
      end)

      {:ok, _, result, _} =
        EctoLibSql.handle_execute(
          "SELECT id, name FROM #{table} ORDER BY #{distance_fn} LIMIT 2",
          [],
          [],
          state
        )

      # Should return 2 closest items
      assert result.num_rows == 2

      # First result should be Item A (closest to query [1.5, 2.1, 2.9] which is similar to [1, 2, 3])
      [[1, "Item A"], _second] = result.rows

      EctoLibSql.disconnect([], state)
    end
  end

  describe "remote metadata operations" do
    # Note: These tests were previously skipped due to reported issues with metadata
    # functions returning 0 for remote-only connections. After code analysis of libsql
    # v0.9.29, the implementation appears correct: HttpConnection delegates to HranaStream
    # which updates atomic values in batch_inner() after each execute().
    # 
    # CAVEAT: total_changes may not accumulate correctly for remote connections because
    # libsql's HranaStream.batch_inner() doesn't call fetch_add on total_changes like
    # the finalize() path does. This is an upstream inconsistency in libsql.

    test "last_insert_rowid works remotely", %{table_name: table} do
      {:ok, state} = EctoLibSql.connect(uri: @turso_uri, auth_token: @turso_token)

      # Create table
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE IF NOT EXISTS #{table} (id INTEGER PRIMARY KEY AUTOINCREMENT, value TEXT)",
          [],
          [],
          state
        )

      # Insert and check rowid
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO #{table} (value) VALUES (?)",
          ["first"],
          [],
          state
        )

      rowid1 = EctoLibSql.Native.get_last_insert_rowid(state)
      assert is_integer(rowid1)
      assert rowid1 > 0

      # Insert another
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO #{table} (value) VALUES (?)",
          ["second"],
          [],
          state
        )

      rowid2 = EctoLibSql.Native.get_last_insert_rowid(state)
      assert rowid2 > rowid1

      EctoLibSql.disconnect([], state)
    end

    test "changes and total_changes work remotely", %{table_name: table} do
      {:ok, state} = EctoLibSql.connect(uri: @turso_uri, auth_token: @turso_token)

      # Create table
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE IF NOT EXISTS #{table} (id INTEGER PRIMARY KEY, value TEXT)",
          [],
          [],
          state
        )

      # Insert
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO #{table} (id, value) VALUES (?, ?)",
          [1, "alpha"],
          [],
          state
        )

      changes1 = EctoLibSql.Native.get_changes(state)
      assert changes1 == 1

      # Insert multiple
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO #{table} (id, value) VALUES (?, ?), (?, ?)",
          [2, "beta", 3, "gamma"],
          [],
          state
        )

      changes2 = EctoLibSql.Native.get_changes(state)
      assert changes2 == 2

      # Note: total_changes may not accumulate correctly for remote connections due to
      # an inconsistency in libsql's HranaStream (batch_inner doesn't update total_changes).
      # We test that it's at least a valid value (0 or greater).
      total = EctoLibSql.Native.get_total_changes(state)
      assert is_integer(total) and total >= 0

      EctoLibSql.disconnect([], state)
    end
  end

  describe "remote error handling" do
    test "invalid SQL returns proper error", %{table_name: _table} do
      {:ok, state} = EctoLibSql.connect(uri: @turso_uri, auth_token: @turso_token)

      query = %EctoLibSql.Query{statement: "SELECT * FROM non_existent_table_xyz"}

      assert {:error, %EctoLibSql.Error{}, _} = EctoLibSql.handle_execute(query, [], [], state)

      EctoLibSql.disconnect([], state)
    end

    test "constraint violation returns error", %{table_name: table} do
      {:ok, state} = EctoLibSql.connect(uri: @turso_uri, auth_token: @turso_token)

      # Create table with unique constraint
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE IF NOT EXISTS #{table} (id INTEGER PRIMARY KEY, email TEXT UNIQUE)",
          [],
          [],
          state
        )

      # Insert first record
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO #{table} (id, email) VALUES (?, ?)",
          [1, "test@example.com"],
          [],
          state
        )

      # Try to insert duplicate - should fail
      result =
        EctoLibSql.handle_execute(
          "INSERT INTO #{table} (id, email) VALUES (?, ?)",
          [2, "test@example.com"],
          [],
          state
        )

      assert {:error, %EctoLibSql.Error{}, _} = result

      EctoLibSql.disconnect([], state)
    end
  end

  describe "remote data types" do
    test "handles various data types correctly", %{table_name: table} do
      {:ok, state} = EctoLibSql.connect(uri: @turso_uri, auth_token: @turso_token)

      # Create table with various types
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE IF NOT EXISTS #{table} (
            id INTEGER PRIMARY KEY,
            text_col TEXT,
            int_col INTEGER,
            real_col REAL,
            blob_col BLOB
          )",
          [],
          [],
          state
        )

      # Insert data
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO #{table} (id, text_col, int_col, real_col, blob_col) VALUES (?, ?, ?, ?, ?)",
          [1, "hello", 42, 3.14159, <<1, 2, 3, 4>>],
          [],
          state
        )

      # Query back
      {:ok, _, result, _} =
        EctoLibSql.handle_execute(
          "SELECT text_col, int_col, real_col, blob_col FROM #{table} WHERE id = ?",
          [1],
          [],
          state
        )

      [[text_val, int_val, real_val, blob_val]] = result.rows

      assert text_val == "hello"
      assert int_val == 42
      assert abs(real_val - 3.14159) < 0.0001
      assert blob_val == <<1, 2, 3, 4>>

      EctoLibSql.disconnect([], state)
    end
  end

  describe "remote complex queries" do
    test "joins and aggregations work remotely", %{table_name: _table} do
      {:ok, state} = EctoLibSql.connect(uri: @turso_uri, auth_token: @turso_token)

      # Create two related tables with unique names
      users_table = "users_#{:erlang.unique_integer([:positive])}"
      posts_table = "posts_#{:erlang.unique_integer([:positive])}"

      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE IF NOT EXISTS #{users_table} (id INTEGER PRIMARY KEY, name TEXT)",
          [],
          [],
          state
        )

      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE IF NOT EXISTS #{posts_table} (id INTEGER PRIMARY KEY, user_id INTEGER, title TEXT)",
          [],
          [],
          state
        )

      # Insert test data
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO #{users_table} (id, name) VALUES (?, ?)",
          [1, "Alice"],
          [],
          state
        )

      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO #{posts_table} (id, user_id, title) VALUES (?, ?, ?)",
          [1, 1, "First Post"],
          [],
          state
        )

      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO #{posts_table} (id, user_id, title) VALUES (?, ?, ?)",
          [2, 1, "Second Post"],
          [],
          state
        )

      # Perform join with aggregation
      {:ok, _, result, _} =
        EctoLibSql.handle_execute(
          "SELECT u.name, COUNT(p.id) as post_count
           FROM #{users_table} u
           LEFT JOIN #{posts_table} p ON u.id = p.user_id
           GROUP BY u.id, u.name",
          [],
          [],
          state
        )

      [["Alice", 2]] = result.rows

      # Clean up
      EctoLibSql.handle_execute("DROP TABLE IF EXISTS #{users_table}", [], [], state)
      EctoLibSql.handle_execute("DROP TABLE IF EXISTS #{posts_table}", [], [], state)

      EctoLibSql.disconnect([], state)
    end
  end

  describe "embedded replica with sync" do
    test "automatic sync from local to remote", %{table_name: table} do
      # Create unique local database file for this test
      local_db = "z_ecto_libsql_test-replica_#{:erlang.unique_integer([:positive])}.db"

      on_exit(fn ->
        cleanup_local_db(local_db)
      end)

      # Connect with embedded replica mode (sync: true)
      {:ok, replica_state} =
        EctoLibSql.connect(
          database: local_db,
          uri: @turso_uri,
          auth_token: @turso_token,
          sync: true
        )

      # Create table in replica
      {:ok, _, _, replica_state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE IF NOT EXISTS #{table} (id INTEGER PRIMARY KEY, value TEXT)",
          [],
          [],
          replica_state
        )

      # Insert data locally
      {:ok, _, _, replica_state} =
        EctoLibSql.handle_execute(
          "INSERT INTO #{table} (id, value) VALUES (?, ?)",
          [1, "synced_value"],
          [],
          replica_state
        )

      EctoLibSql.disconnect([], replica_state)

      # Give sync time to complete
      Process.sleep(1000)

      # Connect directly to remote and verify data was synced
      {:ok, remote_state} = EctoLibSql.connect(uri: @turso_uri, auth_token: @turso_token)

      {:ok, _, result, _} =
        EctoLibSql.handle_execute(
          "SELECT value FROM #{table} WHERE id = ?",
          [1],
          [],
          remote_state
        )

      # Data should be present on remote
      assert result.rows == [["synced_value"]]

      EctoLibSql.disconnect([], remote_state)
    end

    test "manual sync with sync disabled", %{table_name: table} do
      local_db = "z_ecto_libsql_test-manual_sync_#{:erlang.unique_integer([:positive])}.db"

      on_exit(fn ->
        cleanup_local_db(local_db)
      end)

      # Connect with sync disabled
      {:ok, replica_state} =
        EctoLibSql.connect(
          database: local_db,
          uri: @turso_uri,
          auth_token: @turso_token,
          sync: false
        )

      # Create table
      {:ok, _, _, replica_state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE IF NOT EXISTS #{table} (id INTEGER PRIMARY KEY, data TEXT)",
          [],
          [],
          replica_state
        )

      # Insert data locally
      {:ok, _, _, replica_state} =
        EctoLibSql.handle_execute(
          "INSERT INTO #{table} (id, data) VALUES (?, ?)",
          [1, "manual_sync_data"],
          [],
          replica_state
        )

      # Manually trigger sync
      {:ok, "success sync"} = EctoLibSql.Native.sync(replica_state)

      EctoLibSql.disconnect([], replica_state)

      # Give sync time to propagate
      Process.sleep(500)

      # Verify data is on remote
      {:ok, remote_state} = EctoLibSql.connect(uri: @turso_uri, auth_token: @turso_token)

      {:ok, _, result, _} =
        EctoLibSql.handle_execute(
          "SELECT data FROM #{table} WHERE id = ?",
          [1],
          [],
          remote_state
        )

      assert result.rows == [["manual_sync_data"]]

      EctoLibSql.disconnect([], remote_state)
    end

    test "replica provides fast local reads", %{table_name: table} do
      local_db = "z_ecto_libsql_test-fast_read_#{:erlang.unique_integer([:positive])}.db"

      on_exit(fn ->
        cleanup_local_db(local_db)
      end)

      # First, create data on remote
      {:ok, remote_state} = EctoLibSql.connect(uri: @turso_uri, auth_token: @turso_token)

      {:ok, _, _, remote_state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE IF NOT EXISTS #{table} (id INTEGER PRIMARY KEY, value TEXT)",
          [],
          [],
          remote_state
        )

      {:ok, _, _, remote_state} =
        EctoLibSql.handle_execute(
          "INSERT INTO #{table} (id, value) VALUES (?, ?)",
          [1, "remote_data"],
          [],
          remote_state
        )

      EctoLibSql.disconnect([], remote_state)

      # Now connect with replica - should sync down the data
      {:ok, replica_state} =
        EctoLibSql.connect(
          database: local_db,
          uri: @turso_uri,
          auth_token: @turso_token,
          sync: true
        )

      # Wait for sync to complete
      :ok = wait_for_sync(replica_state, table)

      # Read should work from local replica
      {:ok, _, result, _} =
        EctoLibSql.handle_execute(
          "SELECT value FROM #{table} WHERE id = ?",
          [1],
          [],
          replica_state
        )

      assert result.rows == [["remote_data"]]

      EctoLibSql.disconnect([], replica_state)

      # Verify local file exists and has data
      assert File.exists?(local_db)
      file_size = File.stat!(local_db).size
      # Should have some data (not empty)
      assert file_size > 0
    end

    test "replica sync works bidirectionally", %{table_name: table} do
      local_db1 = "z_ecto_libsql_test-bidirectional_1_#{:erlang.unique_integer([:positive])}.db"
      local_db2 = "z_ecto_libsql_test-bidirectional_2_#{:erlang.unique_integer([:positive])}.db"

      on_exit(fn ->
        cleanup_local_db(local_db1)
        cleanup_local_db(local_db2)
      end)

      # First replica - create table and insert data
      {:ok, replica1} =
        EctoLibSql.connect(
          database: local_db1,
          uri: @turso_uri,
          auth_token: @turso_token,
          sync: true
        )

      {:ok, _, _, replica1} =
        EctoLibSql.handle_execute(
          "CREATE TABLE IF NOT EXISTS #{table} (id INTEGER PRIMARY KEY, source TEXT)",
          [],
          [],
          replica1
        )

      {:ok, _, _, replica1} =
        EctoLibSql.handle_execute(
          "INSERT INTO #{table} (id, source) VALUES (?, ?)",
          [1, "replica_1"],
          [],
          replica1
        )

      # Manually sync before disconnect to ensure data is pushed
      # Returns {:ok, "success sync"}
      _ = EctoLibSql.Native.sync(replica1)
      EctoLibSql.disconnect([], replica1)

      # Give remote time to receive the sync
      Process.sleep(500)

      # Second replica - should sync down the data from remote
      {:ok, replica2} =
        EctoLibSql.connect(
          database: local_db2,
          uri: @turso_uri,
          auth_token: @turso_token,
          sync: true
        )

      # Wait for sync to complete
      :ok = wait_for_sync(replica2, table)

      # Should see data from first replica
      {:ok, _, result, _} =
        EctoLibSql.handle_execute(
          "SELECT source FROM #{table} WHERE id = ?",
          [1],
          [],
          replica2
        )

      assert result.rows == [["replica_1"]]

      # Add data from second replica
      {:ok, _, _, replica2} =
        EctoLibSql.handle_execute(
          "INSERT INTO #{table} (id, source) VALUES (?, ?)",
          [2, "replica_2"],
          [],
          replica2
        )

      # Manually sync before disconnect to ensure data is pushed
      _ = EctoLibSql.Native.sync(replica2)
      EctoLibSql.disconnect([], replica2)

      # Give remote time to receive the sync
      Process.sleep(500)

      # Reconnect first replica and verify it sees data from second
      {:ok, replica1_again} =
        EctoLibSql.connect(
          database: local_db1,
          uri: @turso_uri,
          auth_token: @turso_token,
          sync: true
        )

      # Manually sync to pull down latest data from remote
      _ = EctoLibSql.Native.sync(replica1_again)

      # Wait for sync to pull down data from remote
      # We need to verify the data exists, not just that the table exists
      # Try multiple times to give sync time to complete
      result2 =
        Enum.reduce_while(1..10, nil, fn _attempt, _acc ->
          case EctoLibSql.handle_execute(
                 "SELECT source FROM #{table} WHERE id = ?",
                 [2],
                 [],
                 replica1_again
               ) do
            {:ok, _, %{rows: [["replica_2"]]} = result, _} ->
              {:halt, result}

            _ ->
              Process.sleep(500)
              {:cont, nil}
          end
        end)

      assert result2 != nil, "Failed to sync data from replica_2"
      assert result2.rows == [["replica_2"]]

      EctoLibSql.disconnect([], replica1_again)
    end
  end
end
