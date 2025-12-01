defmodule EctoLibSql.TursoMissingFeaturesTest do
  @moduledoc """
  Test suite for Turso features that are currently missing from ecto_libsql.

  These tests are marked as pending (@tag :pending) and serve as specifications
  for the features we need to implement. Each test demonstrates:
  1. The desired API
  2. Expected behavior
  3. Error handling

  Priority order follows TURSO_FEATURE_GAP_ANALYSIS.md.

  ## Implementation Status
  - [ ] P0-1: busy_timeout()
  - [ ] P0-2: execute_batch() native
  - [ ] P0-3: PRAGMA support
  - [ ] P0-4: Statement columns()
  - [ ] P1-5: query_row()
  - [ ] P1-6: cacheflush()
  - [ ] P1-7: Statement reset()
  - [ ] P1-8: MVCC mode
  """

  use ExUnit.Case
  import ExUnit.CaptureLog

  @moduletag :turso_missing_features

  # ============================================================================
  # P0-1: busy_timeout() - CRITICAL
  # ============================================================================

  @tag :pending
  describe "busy_timeout/2" do
    test "sets busy timeout on connection" do
      {:ok, state} = EctoLibSql.connect(database: ":memory:")

      # Set timeout to 5 seconds (5000 milliseconds)
      assert {:ok, _state} = EctoLibSql.Native.set_busy_timeout(state, 5000)

      # Cleanup
      EctoLibSql.disconnect([], state)
    end

    test "busy timeout prevents immediate database locked errors" do
      db_path = "test_busy_#{:erlang.unique_integer()}.db"

      # Connection 1 - start a write transaction
      {:ok, state1} = EctoLibSql.connect(database: db_path)
      {:ok, state1} = EctoLibSql.Native.begin(state1, behavior: :immediate)

      # Connection 2 - should wait instead of immediate error
      {:ok, state2} = EctoLibSql.connect(database: db_path)
      {:ok, state2} = EctoLibSql.Native.set_busy_timeout(state2, 2000)

      # This should wait up to 2 seconds instead of failing immediately
      start_time = System.monotonic_time(:millisecond)

      # Spawn task to release lock after 500ms
      spawn(fn ->
        Process.sleep(500)
        EctoLibSql.Native.commit(state1)
      end)

      # This should succeed because lock will be released
      {:ok, query, _result, _state2} =
        EctoLibSql.handle_execute("SELECT 1", [], [], state2)

      elapsed = System.monotonic_time(:millisecond) - start_time

      # Should have waited ~500ms, not failed immediately
      assert elapsed >= 400
      assert elapsed < 2000

      # Cleanup
      EctoLibSql.disconnect([], state1)
      EctoLibSql.disconnect([], state2)
      File.rm(db_path)
    end

    test "busy timeout can be set in connection options" do
      db_path = "test_busy_opts_#{:erlang.unique_integer()}.db"

      {:ok, state} =
        EctoLibSql.connect(database: db_path, busy_timeout: 3000)

      # Should have busy timeout set from config
      # We can't directly check this, but can verify behavior
      assert state.conn_id

      EctoLibSql.disconnect([], state)
      File.rm(db_path)
    end

    test "busy timeout with 0 disables waiting" do
      {:ok, state} = EctoLibSql.connect(database: ":memory:")

      # Disable busy timeout
      assert {:ok, _state} = EctoLibSql.Native.set_busy_timeout(state, 0)

      EctoLibSql.disconnect([], state)
    end
  end

  # ============================================================================
  # P0-2: Native execute_batch() - CRITICAL
  # ============================================================================

  @tag :pending
  describe "execute_batch/2 native" do
    test "executes multiple statements from single string" do
      {:ok, state} = EctoLibSql.connect(database: ":memory:")

      # Multi-statement SQL (like migrations)
      batch_sql = """
      CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);
      CREATE INDEX idx_users_name ON users(name);
      INSERT INTO users (id, name) VALUES (1, 'Alice');
      INSERT INTO users (id, name) VALUES (2, 'Bob');
      CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER);
      """

      # Should execute all statements atomically
      assert {:ok, state} = EctoLibSql.Native.execute_batch_native(state, batch_sql)

      # Verify all statements executed
      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute("SELECT COUNT(*) FROM users", [], [], state)

      assert [[2]] = result.rows

      EctoLibSql.disconnect([], state)
    end

    test "execute_batch handles errors in multi-statement SQL" do
      {:ok, state} = EctoLibSql.connect(database: ":memory:")

      # Invalid SQL should error
      batch_sql = """
      CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);
      INSERT INTO nonexistent_table VALUES (1);
      INSERT INTO users VALUES (1, 'Alice');
      """

      # Should fail on second statement
      assert {:error, _reason} = EctoLibSql.Native.execute_batch_native(state, batch_sql)

      EctoLibSql.disconnect([], state)
    end

    test "execute_batch is faster than individual queries" do
      {:ok, state} = EctoLibSql.connect(database: ":memory:")

      # Create table
      EctoLibSql.handle_execute(
        "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)",
        [],
        [],
        state
      )

      # Generate large batch
      inserts =
        for i <- 1..100 do
          "INSERT INTO users (id, name) VALUES (#{i}, 'User#{i}');"
        end

      batch_sql = Enum.join(inserts, "\n")

      # Time native batch
      {batch_time, {:ok, _state}} =
        :timer.tc(fn -> EctoLibSql.Native.execute_batch_native(state, batch_sql) end)

      batch_time_ms = batch_time / 1000

      # Native batch should be fast (< 100ms for 100 inserts)
      assert batch_time_ms < 100

      EctoLibSql.disconnect([], state)
    end
  end

  # ============================================================================
  # P0-3: PRAGMA Support - CRITICAL
  # ============================================================================

  @tag :pending
  describe "PRAGMA support" do
    test "pragma_query sets and gets values" do
      {:ok, state} = EctoLibSql.connect(database: ":memory:")

      # Set foreign keys ON
      assert {:ok, "ON"} = EctoLibSql.Native.pragma_query(state, "foreign_keys", "ON")

      # Get current value
      assert {:ok, "ON"} = EctoLibSql.Native.pragma_query(state, "foreign_keys")

      EctoLibSql.disconnect([], state)
    end

    test "pragma_query handles journal_mode" do
      db_path = "test_pragma_#{:erlang.unique_integer()}.db"
      {:ok, state} = EctoLibSql.connect(database: db_path)

      # Set WAL mode
      assert {:ok, "wal"} = EctoLibSql.Native.pragma_query(state, "journal_mode", "WAL")

      # Verify it's set
      assert {:ok, "wal"} = EctoLibSql.Native.pragma_query(state, "journal_mode")

      EctoLibSql.disconnect([], state)
      File.rm(db_path)
    end

    test "pragma_query gets table_info" do
      {:ok, state} = EctoLibSql.connect(database: ":memory:")

      # Create table
      EctoLibSql.handle_execute(
        "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER)",
        [],
        [],
        state
      )

      # Get table info
      assert {:ok, columns} = EctoLibSql.Native.pragma_query(state, "table_info", "users")

      # Should return column information
      assert is_list(columns)
      assert length(columns) == 3

      # Each column should have: cid, name, type, notnull, dflt_value, pk
      [id_col, name_col, age_col] = columns

      assert id_col["name"] == "id"
      assert id_col["type"] == "INTEGER"
      assert id_col["pk"] == 1

      assert name_col["name"] == "name"
      assert name_col["type"] == "TEXT"
      assert name_col["notnull"] == 1

      assert age_col["name"] == "age"
      assert age_col["type"] == "INTEGER"

      EctoLibSql.disconnect([], state)
    end

    test "pragma_query sets cache_size" do
      {:ok, state} = EctoLibSql.connect(database: ":memory:")

      # Set cache size to 64MB (negative means KB)
      assert {:ok, _} = EctoLibSql.Native.pragma_query(state, "cache_size", "-64000")

      # Verify
      assert {:ok, "-64000"} = EctoLibSql.Native.pragma_query(state, "cache_size")

      EctoLibSql.disconnect([], state)
    end

    test "pragma_query handles synchronous mode" do
      {:ok, state} = EctoLibSql.connect(database: ":memory:")

      # Set synchronous to NORMAL
      assert {:ok, "1"} = EctoLibSql.Native.pragma_query(state, "synchronous", "NORMAL")

      # Set to FULL
      assert {:ok, "2"} = EctoLibSql.Native.pragma_query(state, "synchronous", "FULL")

      EctoLibSql.disconnect([], state)
    end

    test "high-level PRAGMA helpers" do
      {:ok, state} = EctoLibSql.connect(database: ":memory:")

      # Ergonomic API
      assert {:ok, _} = EctoLibSql.Pragma.enable_foreign_keys(state)
      assert {:ok, true} = EctoLibSql.Pragma.foreign_keys_enabled?(state)

      assert {:ok, _} = EctoLibSql.Pragma.set_wal_mode(state)
      assert {:ok, :wal} = EctoLibSql.Pragma.get_journal_mode(state)

      assert {:ok, _} = EctoLibSql.Pragma.set_cache_size(state, megabytes: 64)

      assert {:ok, columns} = EctoLibSql.Pragma.table_info(state, "sqlite_master")
      assert is_list(columns)

      EctoLibSql.disconnect([], state)
    end
  end

  # ============================================================================
  # P0-4: Statement columns() - CRITICAL
  # ============================================================================

  @tag :pending
  describe "Statement.columns()" do
    test "get column metadata from prepared statement" do
      {:ok, state} = EctoLibSql.connect(database: ":memory:")

      # Create table
      EctoLibSql.handle_execute(
        "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER, created_at TEXT)",
        [],
        [],
        state
      )

      # Prepare statement
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "SELECT * FROM users WHERE id = ?")

      # Get columns
      assert {:ok, columns} = EctoLibSql.Native.get_statement_columns(stmt_id)

      assert length(columns) == 4

      assert %{name: "id", decl_type: "INTEGER"} = Enum.at(columns, 0)
      assert %{name: "name", decl_type: "TEXT"} = Enum.at(columns, 1)
      assert %{name: "age", decl_type: "INTEGER"} = Enum.at(columns, 2)
      assert %{name: "created_at", decl_type: "TEXT"} = Enum.at(columns, 3)

      # Cleanup
      EctoLibSql.Native.close_stmt(stmt_id)
      EctoLibSql.disconnect([], state)
    end

    test "columns work with complex queries" do
      {:ok, state} = EctoLibSql.connect(database: ":memory:")

      # Create tables
      EctoLibSql.handle_execute(
        "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)",
        [],
        [],
        state
      )

      EctoLibSql.handle_execute(
        "CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER, title TEXT)",
        [],
        [],
        state
      )

      # Prepare complex query
      {:ok, stmt_id} =
        EctoLibSql.Native.prepare(
          state,
          """
          SELECT
            u.id as user_id,
            u.name,
            COUNT(p.id) as post_count
          FROM users u
          LEFT JOIN posts p ON u.id = p.user_id
          GROUP BY u.id
          """
        )

      # Get columns
      assert {:ok, columns} = EctoLibSql.Native.get_statement_columns(stmt_id)

      assert length(columns) == 3

      # Column names from query
      assert %{name: "user_id"} = Enum.at(columns, 0)
      assert %{name: "name"} = Enum.at(columns, 1)
      assert %{name: "post_count"} = Enum.at(columns, 2)

      # Cleanup
      EctoLibSql.Native.close_stmt(stmt_id)
      EctoLibSql.disconnect([], state)
    end
  end

  # ============================================================================
  # P1-5: query_row() - HIGH PRIORITY
  # ============================================================================

  @tag :pending
  describe "query_row/3" do
    test "returns single row from query" do
      {:ok, state} = EctoLibSql.connect(database: ":memory:")

      # Create and populate table
      EctoLibSql.handle_execute(
        "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)",
        [],
        [],
        state
      )

      EctoLibSql.handle_execute("INSERT INTO users VALUES (1, 'Alice', 30)", [], [], state)

      # Prepare statement
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "SELECT name, age FROM users WHERE id = ?")

      # Query single row
      assert {:ok, row} = EctoLibSql.Native.query_row(state, stmt_id, [1])

      assert ["Alice", 30] = row

      # Cleanup
      EctoLibSql.Native.close_stmt(stmt_id)
      EctoLibSql.disconnect([], state)
    end

    test "query_row errors if no rows" do
      {:ok, state} = EctoLibSql.connect(database: ":memory:")

      EctoLibSql.handle_execute(
        "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)",
        [],
        [],
        state
      )

      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "SELECT * FROM users WHERE id = ?")

      # Should error if no rows
      assert {:error, :no_rows} = EctoLibSql.Native.query_row(state, stmt_id, [999])

      EctoLibSql.Native.close_stmt(stmt_id)
      EctoLibSql.disconnect([], state)
    end

    test "query_row errors if multiple rows" do
      {:ok, state} = EctoLibSql.connect(database: ":memory:")

      EctoLibSql.handle_execute(
        "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)",
        [],
        [],
        state
      )

      EctoLibSql.handle_execute("INSERT INTO users VALUES (1, 'Alice')", [], [], state)
      EctoLibSql.handle_execute("INSERT INTO users VALUES (2, 'Bob')", [], [], state)

      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "SELECT * FROM users")

      # Should error if multiple rows
      assert {:error, :multiple_rows} = EctoLibSql.Native.query_row(state, stmt_id, [])

      EctoLibSql.Native.close_stmt(stmt_id)
      EctoLibSql.disconnect([], state)
    end

    test "query_row is more efficient than query + take first" do
      {:ok, state} = EctoLibSql.connect(database: ":memory:")

      # Create table with many rows
      EctoLibSql.handle_execute(
        "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)",
        [],
        [],
        state
      )

      # Insert 1000 rows
      for i <- 1..1000 do
        EctoLibSql.handle_execute(
          "INSERT INTO users VALUES (?, ?)",
          [i, "User#{i}"],
          [],
          state
        )
      end

      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "SELECT * FROM users")

      # query_row should stop after first row (fast)
      {time_query_row, {:error, :multiple_rows}} =
        :timer.tc(fn -> EctoLibSql.Native.query_row(state, stmt_id, []) end)

      # Should be fast even though table has 1000 rows
      # (It should error quickly after seeing 2nd row)
      assert time_query_row / 1000 < 10

      # Compare to fetching all rows
      {:ok, stmt_id2} = EctoLibSql.Native.prepare(state, "SELECT * FROM users")

      {time_query_all, {:ok, _result}} =
        :timer.tc(fn -> EctoLibSql.Native.query_stmt(state, stmt_id2, []) end)

      # query_row should be much faster (doesn't fetch all 1000 rows)
      assert time_query_row < time_query_all / 2

      EctoLibSql.Native.close_stmt(stmt_id)
      EctoLibSql.Native.close_stmt(stmt_id2)
      EctoLibSql.disconnect([], state)
    end
  end

  # ============================================================================
  # P1-6: cacheflush() - HIGH PRIORITY
  # ============================================================================

  @tag :pending
  describe "cacheflush/1" do
    test "flushes dirty pages to disk" do
      db_path = "test_cacheflush_#{:erlang.unique_integer()}.db"
      {:ok, state} = EctoLibSql.connect(database: db_path)

      # Create table and insert data
      EctoLibSql.handle_execute(
        "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)",
        [],
        [],
        state
      )

      EctoLibSql.handle_execute("INSERT INTO users VALUES (1, 'Alice')", [], [], state)

      # Flush to disk
      assert {:ok, _state} = EctoLibSql.Native.cacheflush(state)

      # At this point, data should be durable even without closing connection
      # (Verify by opening new connection)
      {:ok, state2} = EctoLibSql.connect(database: db_path)

      {:ok, _query, result, _state2} =
        EctoLibSql.handle_execute("SELECT COUNT(*) FROM users", [], [], state2)

      assert [[1]] = result.rows

      # Cleanup
      EctoLibSql.disconnect([], state)
      EctoLibSql.disconnect([], state2)
      File.rm(db_path)
    end

    test "cacheflush before backup ensures consistency" do
      db_path = "test_backup_#{:erlang.unique_integer()}.db"
      backup_path = "test_backup_#{:erlang.unique_integer()}_copy.db"

      {:ok, state} = EctoLibSql.connect(database: db_path)

      # Create and populate table
      EctoLibSql.handle_execute(
        "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)",
        [],
        [],
        state
      )

      EctoLibSql.handle_execute("INSERT INTO users VALUES (1, 'Alice')", [], [], state)
      EctoLibSql.handle_execute("INSERT INTO users VALUES (2, 'Bob')", [], [], state)

      # Flush before backup
      {:ok, _state} = EctoLibSql.Native.cacheflush(state)

      # Copy database file
      File.cp!(db_path, backup_path)

      # Verify backup is complete
      {:ok, backup_state} = EctoLibSql.connect(database: backup_path)

      {:ok, _query, result, _backup_state} =
        EctoLibSql.handle_execute("SELECT COUNT(*) FROM users", [], [], backup_state)

      assert [[2]] = result.rows

      # Cleanup
      EctoLibSql.disconnect([], state)
      EctoLibSql.disconnect([], backup_state)
      File.rm(db_path)
      File.rm(backup_path)
    end
  end

  # ============================================================================
  # P1-7: Statement reset() - HIGH PRIORITY
  # ============================================================================

  @tag :pending
  describe "Statement.reset()" do
    test "reset statement for reuse without re-prepare" do
      {:ok, state} = EctoLibSql.connect(database: ":memory:")

      # Create table
      EctoLibSql.handle_execute(
        "CREATE TABLE logs (id INTEGER PRIMARY KEY AUTOINCREMENT, message TEXT)",
        [],
        [],
        state
      )

      # Prepare statement once
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "INSERT INTO logs (message) VALUES (?)")

      # Execute multiple times with reset
      for i <- 1..5 do
        {:ok, _rows} = EctoLibSql.Native.execute_stmt(state, stmt_id, "INSERT ...", ["Log #{i}"])

        # Reset for reuse
        {:ok, _} = EctoLibSql.Native.reset_stmt(stmt_id)
      end

      # Verify all inserts succeeded
      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute("SELECT COUNT(*) FROM logs", [], [], state)

      assert [[5]] = result.rows

      # Cleanup
      EctoLibSql.Native.close_stmt(stmt_id)
      EctoLibSql.disconnect([], state)
    end

    test "reset clears parameter bindings" do
      {:ok, state} = EctoLibSql.connect(database: ":memory:")

      EctoLibSql.handle_execute(
        "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)",
        [],
        [],
        state
      )

      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "INSERT INTO users VALUES (?, ?)")

      # Execute with parameters
      {:ok, _} = EctoLibSql.Native.execute_stmt(state, stmt_id, "INSERT ...", [1, "Alice"])

      # Reset clears bindings
      {:ok, _} = EctoLibSql.Native.reset_stmt(stmt_id)

      # Execute with different parameters
      {:ok, _} = EctoLibSql.Native.execute_stmt(state, stmt_id, "INSERT ...", [2, "Bob"])

      # Verify both inserts
      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute("SELECT name FROM users ORDER BY id", [], [], state)

      assert [["Alice"], ["Bob"]] = result.rows

      EctoLibSql.Native.close_stmt(stmt_id)
      EctoLibSql.disconnect([], state)
    end

    test "reset is faster than re-prepare" do
      {:ok, state} = EctoLibSql.connect(database: ":memory:")

      EctoLibSql.handle_execute(
        "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)",
        [],
        [],
        state
      )

      sql = "INSERT INTO users VALUES (?, ?)"

      # Benchmark with reset
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, sql)

      {time_with_reset, _} =
        :timer.tc(fn ->
          for i <- 1..100 do
            EctoLibSql.Native.execute_stmt(state, stmt_id, sql, [i, "User#{i}"])
            EctoLibSql.Native.reset_stmt(stmt_id)
          end
        end)

      EctoLibSql.Native.close_stmt(stmt_id)

      # Clear table
      EctoLibSql.handle_execute("DELETE FROM users", [], [], state)

      # Benchmark with re-prepare
      {time_with_prepare, _} =
        :timer.tc(fn ->
          for i <- 1..100 do
            {:ok, stmt} = EctoLibSql.Native.prepare(state, sql)
            EctoLibSql.Native.execute_stmt(state, stmt, sql, [i + 100, "User#{i}"])
            EctoLibSql.Native.close_stmt(stmt)
          end
        end)

      # Reset should be significantly faster
      assert time_with_reset < time_with_prepare / 2

      EctoLibSql.disconnect([], state)
    end
  end

  # ============================================================================
  # P1-8: MVCC Mode - HIGH PRIORITY
  # ============================================================================

  @tag :pending
  describe "MVCC mode" do
    test "enable MVCC at connection time" do
      db_path = "test_mvcc_#{:erlang.unique_integer()}.db"

      {:ok, state} = EctoLibSql.connect(database: db_path, mvcc: true)

      # MVCC should be enabled
      # We can't directly check this, but can verify connection works
      assert state.conn_id

      EctoLibSql.disconnect([], state)
      File.rm(db_path)
    end

    test "MVCC allows concurrent reads during write" do
      db_path = "test_mvcc_concurrent_#{:erlang.unique_integer()}.db"

      # Create database with MVCC
      {:ok, write_state} = EctoLibSql.connect(database: db_path, mvcc: true)

      # Create table and initial data
      EctoLibSql.handle_execute(
        "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)",
        [],
        [],
        write_state
      )

      EctoLibSql.handle_execute("INSERT INTO users VALUES (1, 'Alice')", [], [], write_state)

      # Start long-running write transaction
      {:ok, write_state} = EctoLibSql.Native.begin(write_state, behavior: :immediate)

      EctoLibSql.handle_execute("INSERT INTO users VALUES (2, 'Bob')", [], [], write_state)

      # Open second connection for reading (should not block)
      {:ok, read_state} = EctoLibSql.connect(database: db_path, mvcc: true)

      # Read should succeed even though write transaction is active
      {:ok, _query, result, _read_state} =
        EctoLibSql.handle_execute("SELECT COUNT(*) FROM users", [], [], read_state)

      # Should see original data (1 row) since write hasn't committed
      assert [[1]] = result.rows

      # Commit write
      {:ok, _} = EctoLibSql.Native.commit(write_state)

      # Now read should see new data
      {:ok, _query, result, _read_state} =
        EctoLibSql.handle_execute("SELECT COUNT(*) FROM users", [], [], read_state)

      assert [[2]] = result.rows

      # Cleanup
      EctoLibSql.disconnect([], write_state)
      EctoLibSql.disconnect([], read_state)
      File.rm(db_path)
    end
  end
end
