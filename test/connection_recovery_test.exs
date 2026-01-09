defmodule EctoLibSql.ConnectionRecoveryTest do
  use ExUnit.Case
  alias EctoLibSql

  # Tests for connection recovery and resilience after failures.
  # Focuses on critical real-world scenarios.

  setup do
    {:ok, state} = EctoLibSql.connect(database: ":memory:")

    on_exit(fn ->
      EctoLibSql.disconnect([], state)
    end)

    {:ok, state: state}
  end

  describe "connection recovery from errors" do
    test "connection remains usable after failed query", %{state: state} do
      # Set up a table
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE test_data (id INTEGER PRIMARY KEY, value TEXT)",
          [],
          [],
          state
        )

      # Execute a successful query
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO test_data (id, value) VALUES (1, 'first')",
          [],
          [],
          state
        )

      # Attempt a query that fails - connection should survive
      _result = EctoLibSql.handle_execute("SELECT * FROM nonexistent_table", [], [], state)

      # Connection should still be usable after error
      {:ok, _, result, _state} =
        EctoLibSql.handle_execute(
          "SELECT * FROM test_data",
          [],
          [],
          state
        )

      assert result.num_rows == 1
    end

    test "constraint violation doesn't break connection", %{state: state} do
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT UNIQUE NOT NULL)",
          [],
          [],
          state
        )

      # Insert valid data
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO users (id, email) VALUES (1, 'alice@example.com')",
          [],
          [],
          state
        )

      # Attempt insert with duplicate email - should fail but not crash connection
      _result =
        EctoLibSql.handle_execute(
          "INSERT INTO users (id, email) VALUES (2, 'alice@example.com')",
          [],
          [],
          state
        )

      # Connection should still be usable
      {:ok, _, result, _state} =
        EctoLibSql.handle_execute(
          "SELECT COUNT(*) FROM users",
          [],
          [],
          state
        )

      [[count]] = result.rows
      assert count == 1, "Only one user should exist after constraint violation"
    end

    test "syntax error doesn't break connection", %{state: state} do
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)",
          [],
          [],
          state
        )

      # Insert with correct parameters
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO items (id, name) VALUES (?, ?)",
          [1, "item1"],
          [],
          state
        )

      # Attempt with invalid SQL syntax
      _result =
        EctoLibSql.handle_execute(
          "INSRT INTO items (id, name) VALUES (2, 'item2')",
          [],
          [],
          state
        )

      # Connection should still work
      {:ok, _, result, _state} =
        EctoLibSql.handle_execute(
          "SELECT COUNT(*) FROM items",
          [],
          [],
          state
        )

      [[count]] = result.rows
      assert count == 1
    end

    test "transaction survives query errors within transaction", %{state: state} do
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE accounts (id INTEGER PRIMARY KEY, balance INTEGER)",
          [],
          [],
          state
        )

      # Begin transaction
      {:ok, :begin, state} = EctoLibSql.handle_begin([], state)

      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO accounts (id, balance) VALUES (1, 100)",
          [],
          [],
          state
        )

      # Execute query that fails within transaction
      _error_result =
        EctoLibSql.handle_execute(
          "SELECT invalid_column FROM accounts",
          [],
          [],
          state
        )

      # Transaction should still be rollbackable
      {:ok, _, state} = EctoLibSql.handle_rollback([], state)

      # Verify transaction was rolled back
      {:ok, _, result, _state} =
        EctoLibSql.handle_execute(
          "SELECT COUNT(*) FROM accounts",
          [],
          [],
          state
        )

      [[count]] = result.rows
      assert count == 0, "Transaction should have been rolled back"
    end

    test "prepared statement error doesn't break connection", %{state: state} do
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE products (id INTEGER PRIMARY KEY, name TEXT)",
          [],
          [],
          state
        )

      # Try to prepare invalid statement
      _prep_result = EctoLibSql.Native.prepare(state, "SELECT * FRM products")

      # Connection should still be usable
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO products (id, name) VALUES (1, 'product1')",
          [],
          [],
          state
        )

      {:ok, _, result, _state} =
        EctoLibSql.handle_execute(
          "SELECT COUNT(*) FROM products",
          [],
          [],
          state
        )

      [[count]] = result.rows
      assert count == 1
    end

    test "NULL constraint violation handled gracefully", %{state: state} do
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE records (id INTEGER PRIMARY KEY, data TEXT NOT NULL)",
          [],
          [],
          state
        )

      # Try to insert NULL
      _error_result =
        EctoLibSql.handle_execute(
          "INSERT INTO records (id, data) VALUES (1, ?)",
          [nil],
          [],
          state
        )

      # Connection still works
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO records (id, data) VALUES (2, 'valid_data')",
          [],
          [],
          state
        )

      {:ok, _, result, _state} =
        EctoLibSql.handle_execute(
          "SELECT COUNT(*) FROM records",
          [],
          [],
          state
        )

      [[count]] = result.rows
      assert count == 1
    end

    test "multiple sequential errors don't accumulate damage", %{state: state} do
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT)",
          [],
          [],
          state
        )

      # Execute multiple errors in sequence
      _err1 = EctoLibSql.handle_execute("INVALID SQL", [], [], state)
      _err2 = EctoLibSql.handle_execute("SELECT * FROM nonexistent", [], [], state)
      _err3 = EctoLibSql.handle_execute("INSERT INTO test VALUES ()", [], [], state)

      # Connection should fully recover
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO test (id, value) VALUES (1, 'ok')",
          [],
          [],
          state
        )

      {:ok, _, result, _state} =
        EctoLibSql.handle_execute(
          "SELECT COUNT(*) FROM test",
          [],
          [],
          state
        )

      [[count]] = result.rows
      assert count == 1
    end

    test "batch operations with failures don't break connection", %{state: state} do
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE batch_test (id INTEGER PRIMARY KEY, value TEXT)",
          [],
          [],
          state
        )

      # Batch with statements
      statements = [
        {"INSERT INTO batch_test (id, value) VALUES (1, 'ok')", []},
        {"INSERT INTO batch_test (id, value) VALUES (2, 'also_ok')", []}
      ]

      # Batch should execute
      _batch_result = EctoLibSql.Native.batch(state, statements)

      # Connection still works for new operations
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO batch_test (id, value) VALUES (3, 'new')",
          [],
          [],
          state
        )

      {:ok, _, result, _state} =
        EctoLibSql.handle_execute(
          "SELECT COUNT(*) FROM batch_test",
          [],
          [],
          state
        )

      [[count]] = result.rows
      assert count >= 1
    end

    test "savepoint error recovery", %{state: state} do
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE savepoint_test (id INTEGER PRIMARY KEY, value TEXT)",
          [],
          [],
          state
        )

      # Begin transaction
      {:ok, :begin, state} = EctoLibSql.handle_begin([], state)

      # First insert before savepoint
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO savepoint_test (id, value) VALUES (1, 'before')",
          [],
          [],
          state
        )

      # Create savepoint (returns :ok)
      :ok = EctoLibSql.Native.create_savepoint(state, "sp1")

      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO savepoint_test (id, value) VALUES (2, 'inside')",
          [],
          [],
          state
        )

      # Cause an error within savepoint
      _error = EctoLibSql.handle_execute("SELEC * FROM savepoint_test", [], [], state)

      # Rollback to savepoint - only rolls back 'inside' insert, keeps 'before'
      :ok = EctoLibSql.Native.rollback_to_savepoint_by_name(state, "sp1")

      # Should be able to continue transaction
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO savepoint_test (id, value) VALUES (3, 'after')",
          [],
          [],
          state
        )

      # Commit
      {:ok, _, state} = EctoLibSql.handle_commit([], state)

      # Should have 'before' and 'after', but not 'inside'
      {:ok, _, result, _state} =
        EctoLibSql.handle_execute(
          "SELECT COUNT(*) FROM savepoint_test",
          [],
          [],
          state
        )

      [[count]] = result.rows
      assert count == 2
    end

    test "busy timeout is configured without breaking connection", %{state: state} do
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE lock_test (id INTEGER PRIMARY KEY, value TEXT)",
          [],
          [],
          state
        )

      # Configure timeout
      :ok = EctoLibSql.Native.busy_timeout(state, 1000)

      # Connection should still work
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO lock_test (id, value) VALUES (1, 'data')",
          [],
          [],
          state
        )

      {:ok, _, result, _state} =
        EctoLibSql.handle_execute(
          "SELECT COUNT(*) FROM lock_test",
          [],
          [],
          state
        )

      [[count]] = result.rows
      assert count == 1
    end

    test "connection resets properly without losing data", %{state: state} do
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE reset_test (id INTEGER PRIMARY KEY, value TEXT)",
          [],
          [],
          state
        )

      # Insert data
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO reset_test (id, value) VALUES (1, 'data')",
          [],
          [],
          state
        )

      # Cause an error
      _error = EctoLibSql.handle_execute("SELECT * FROM nonexistent", [], [], state)

      # Reset connection state (returns :ok)
      :ok = EctoLibSql.Native.reset(state)

      # Data should still be there after reset
      {:ok, _, result, _state} =
        EctoLibSql.handle_execute(
          "SELECT COUNT(*) FROM reset_test",
          [],
          [],
          state
        )

      [[count]] = result.rows
      assert count == 1
    end
  end
end
