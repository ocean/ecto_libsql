defmodule EctoLibSql.BatchFeaturesTest do
  @moduledoc """
  Tests for batch execution features.

  Includes both implemented (transactional/non-transactional batch) and
  unimplemented (native batch via LibSQL API) features.
  """
  use ExUnit.Case

  setup do
    test_db = "z_ecto_libsql_test-batch_#{:erlang.unique_integer([:positive])}.db"

    opts = [database: test_db]

    on_exit(fn ->
      File.rm(test_db)
      File.rm(test_db <> "-shm")
      File.rm(test_db <> "-wal")
    end)

    {:ok, database: test_db, opts: opts}
  end

  describe "native batch execution (SQL string)" do
    test "execute_batch_sql executes multiple statements", %{database: database} do
      {:ok, state} = EctoLibSql.connect(database: database)

      sql = """
      CREATE TABLE batch_test (id INTEGER PRIMARY KEY, name TEXT);
      INSERT INTO batch_test (name) VALUES ('Alice');
      INSERT INTO batch_test (name) VALUES ('Bob');
      SELECT * FROM batch_test ORDER BY id;
      """

      {:ok, results} = EctoLibSql.Native.execute_batch_sql(state, sql)

      # Should have results for all statements
      assert is_list(results)
      assert results != []

      EctoLibSql.disconnect([], state)
    end

    test "execute_transactional_batch_sql is atomic", %{database: database} do
      {:ok, state} = EctoLibSql.connect(database: database)

      # First create a table
      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE atomic_test (id INTEGER PRIMARY KEY, value INTEGER)",
          [],
          [],
          state
        )

      # Insert initial value
      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO atomic_test (id, value) VALUES (1, 100)",
          [],
          [],
          state
        )

      # This should fail (duplicate primary key) and rollback the UPDATE
      sql = """
      UPDATE atomic_test SET value = value - 50 WHERE id = 1;
      INSERT INTO atomic_test (id, value) VALUES (1, 200);
      """

      # Should error due to duplicate key
      assert {:error, _reason} = EctoLibSql.Native.execute_transactional_batch_sql(state, sql)

      # Verify the UPDATE was rolled back
      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute(
          "SELECT value FROM atomic_test WHERE id = 1",
          [],
          [],
          state
        )

      # Value should still be 100 (not 50)
      assert result.rows == [[100]]

      EctoLibSql.disconnect([], state)
    end

    test "execute_batch_sql handles empty results", %{database: database} do
      {:ok, state} = EctoLibSql.connect(database: database)

      sql = """
      CREATE TABLE empty_test (id INTEGER);
      DROP TABLE empty_test;
      """

      {:ok, results} = EctoLibSql.Native.execute_batch_sql(state, sql)

      assert is_list(results)

      EctoLibSql.disconnect([], state)
    end

    test "batch operations - non-transactional", %{database: database} do
      {:ok, state} = EctoLibSql.connect(database: database)

      # Create table
      create_table = %EctoLibSql.Query{
        statement: "CREATE TABLE IF NOT EXISTS batch_test (id INTEGER PRIMARY KEY, value TEXT)"
      }

      {:ok, _query, _result, state} = EctoLibSql.handle_execute(create_table, [], [], state)

      # Execute batch of statements
      statements = [
        {"INSERT INTO batch_test (value) VALUES (?)", ["first"]},
        {"INSERT INTO batch_test (value) VALUES (?)", ["second"]},
        {"INSERT INTO batch_test (value) VALUES (?)", ["third"]},
        {"SELECT COUNT(*) FROM batch_test", []}
      ]

      {:ok, results} = EctoLibSql.Native.batch(state, statements)

      # Should have 4 results (3 inserts + 1 select)
      assert length(results) == 4

      # Last result should be the count query
      count_result = List.last(results)
      # Extract the actual count value from the result rows
      [[count]] = count_result.rows
      assert count == 3

      EctoLibSql.disconnect([], state)
    end

    test "batch operations - transactional atomicity with floats", %{database: database} do
      {:ok, state} = EctoLibSql.connect(database: database)

      # Create table with REAL balance (floats now supported!)
      create_table = %EctoLibSql.Query{
        statement: "CREATE TABLE IF NOT EXISTS accounts (id INTEGER PRIMARY KEY, balance REAL)"
      }

      {:ok, _query, _result, state} = EctoLibSql.handle_execute(create_table, [], [], state)

      # Insert initial account with float
      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO accounts (id, balance) VALUES (?, ?)",
          [1, 100.50],
          [],
          state
        )

      # This batch should fail on the constraint violation and rollback everything
      statements = [
        {"UPDATE accounts SET balance = balance - 25.25 WHERE id = ?", [1]},
        # Duplicate key - will fail
        {"INSERT INTO accounts (id, balance) VALUES (?, ?)", [1, 50.00]}
      ]

      # Should return error
      assert {:error, _reason} = EctoLibSql.Native.batch_transactional(state, statements)

      # Verify balance wasn't changed (rollback worked)
      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute(
          "SELECT balance FROM accounts WHERE id = ?",
          [1],
          [],
          state
        )

      [[balance]] = result.rows
      assert balance == 100.50

      EctoLibSql.disconnect([], state)
    end

    test "batch with mixed operations", %{database: database} do
      {:ok, state} = EctoLibSql.connect(database: database)

      # Create table
      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE IF NOT EXISTS mixed_batch (id INTEGER PRIMARY KEY, val TEXT)",
          [],
          [],
          state
        )

      # Execute batch with inserts, updates, and selects
      statements = [
        {"INSERT INTO mixed_batch (id, val) VALUES (?, ?)", [1, "alpha"]},
        {"INSERT INTO mixed_batch (id, val) VALUES (?, ?)", [2, "beta"]},
        {"UPDATE mixed_batch SET val = ? WHERE id = ?", ["gamma", 1]},
        {"SELECT val FROM mixed_batch WHERE id = ?", [1]},
        {"DELETE FROM mixed_batch WHERE id = ?", [2]},
        {"SELECT COUNT(*) FROM mixed_batch", []}
      ]

      {:ok, results} = EctoLibSql.Native.batch_transactional(state, statements)

      # Should get results for all statements
      assert length(results) == 6

      # Fourth result should be the select showing "gamma"
      select_result = Enum.at(results, 3)
      assert select_result.rows == [["gamma"]]

      # Last result should show count of 1 (one deleted)
      count_result = List.last(results)
      [[count]] = count_result.rows
      assert count == 1

      EctoLibSql.disconnect([], state)
    end

    test "large result set handling with batch insert", %{database: database} do
      {:ok, state} = EctoLibSql.connect(database: database)

      # Create table
      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE IF NOT EXISTS large_test (id INTEGER PRIMARY KEY, category TEXT, value INTEGER)",
          [],
          [],
          state
        )

      # Insert many rows using batch
      insert_statements =
        for i <- 1..100 do
          category = if rem(i, 2) == 0, do: "even", else: "odd"
          {"INSERT INTO large_test (id, category, value) VALUES (?, ?, ?)", [i, category, i * 10]}
        end

      {:ok, _results} = EctoLibSql.Native.batch(state, insert_statements)

      # Query with filter
      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute(
          "SELECT COUNT(*) FROM large_test WHERE category = ?",
          ["even"],
          [],
          state
        )

      [[count]] = result.rows
      assert count == 50

      EctoLibSql.disconnect([], state)
    end
  end
end
