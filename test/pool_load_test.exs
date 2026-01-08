defmodule EctoLibSql.PoolLoadTest do
  @moduledoc """
  Tests for concurrent connection behavior under load.

  Critical scenarios:
  1. Multiple concurrent independent connections
  2. Long-running queries don't cause timeout issues
  3. Connection recovery after errors
  4. Resource cleanup under concurrent load
  5. Transaction isolation under concurrent load

  Note: Tests create separate connections (not pooled) to simulate 
  concurrent access patterns and verify robustness.
  """
  use ExUnit.Case

  alias EctoLibSql

  setup do
    test_db = "z_ecto_libsql_test-pool_#{:erlang.unique_integer([:positive])}.db"

    # Create test table
    {:ok, state} = EctoLibSql.connect(database: test_db)

    {:ok, _query, _result, _state} =
      EctoLibSql.handle_execute(
        "CREATE TABLE test_data (id INTEGER PRIMARY KEY AUTOINCREMENT, value TEXT, duration INTEGER)",
        [],
        [],
        state
      )

    on_exit(fn ->
      EctoLibSql.disconnect([], state)
      File.rm(test_db)
      File.rm(test_db <> "-shm")
      File.rm(test_db <> "-wal")
    end)

    {:ok, test_db: test_db}
  end

  describe "concurrent independent connections" do
    test "multiple concurrent connections execute successfully", %{test_db: test_db} do
      # Spawn 5 concurrent connections
      tasks =
        Enum.map(1..5, fn i ->
          Task.async(fn ->
            {:ok, state} = EctoLibSql.connect(database: test_db)

            result =
              EctoLibSql.handle_execute(
                "INSERT INTO test_data (value) VALUES (?)",
                ["task_#{i}"],
                [],
                state
              )

            EctoLibSql.disconnect([], state)
            result
          end)
        end)

      # Wait for all to complete
      results = Task.await_many(tasks)

      # All should succeed
      Enum.each(results, fn result ->
        assert {:ok, _query, _result, _state} = result
      end)

      # Verify all inserts succeeded
      {:ok, state} = EctoLibSql.connect(database: test_db)

      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute("SELECT COUNT(*) FROM test_data", [], [], state)

      EctoLibSql.disconnect([], state)

      assert [[5]] = result.rows
    end

    test "rapid burst of concurrent connections succeeds", %{test_db: test_db} do
      # Fire 10 connections rapidly
      tasks =
        Enum.map(1..10, fn i ->
          Task.async(fn ->
            {:ok, state} = EctoLibSql.connect(database: test_db)

            result =
              EctoLibSql.handle_execute(
                "INSERT INTO test_data (value) VALUES (?)",
                ["burst_#{i}"],
                [],
                state
              )

            EctoLibSql.disconnect([], state)
            result
          end)
        end)

      results = Task.await_many(tasks)

      # All should succeed
      success_count = Enum.count(results, fn r -> match?({:ok, _, _, _}, r) end)
      assert success_count == 10
    end
  end

  describe "long-running operations" do
    test "long transaction doesn't cause timeout issues", %{test_db: test_db} do
      {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 5000)

      # Start longer transaction
      {:ok, trx_state} = EctoLibSql.Native.begin(state)

      {:ok, _query, _result, trx_state} =
        EctoLibSql.handle_execute(
          "INSERT INTO test_data (value, duration) VALUES (?, ?)",
          ["long", 100],
          [],
          trx_state
        )

      # Simulate some work
      Process.sleep(100)

      {:ok, _committed_state} = EctoLibSql.Native.commit(trx_state)

      EctoLibSql.disconnect([], state)
    end

    test "multiple concurrent transactions complete despite duration", %{test_db: test_db} do
      tasks =
        Enum.map(1..3, fn i ->
          Task.async(fn ->
            {:ok, state} = EctoLibSql.connect(database: test_db)

            {:ok, trx_state} = EctoLibSql.Native.begin(state)

            {:ok, _query, _result, trx_state} =
              EctoLibSql.handle_execute(
                "INSERT INTO test_data (value) VALUES (?)",
                ["trx_#{i}"],
                [],
                trx_state
              )

            # Hold transaction
            Process.sleep(50)

            result = EctoLibSql.Native.commit(trx_state)

            EctoLibSql.disconnect([], state)
            result
          end)
        end)

      results = Task.await_many(tasks)

      # All should succeed
      Enum.each(results, fn result ->
        assert {:ok, _state} = result
      end)

      # Verify all inserts
      {:ok, state} = EctoLibSql.connect(database: test_db)

      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute("SELECT COUNT(*) FROM test_data", [], [], state)

      EctoLibSql.disconnect([], state)

      assert [[3]] = result.rows
    end
  end

  describe "connection recovery" do
    test "connection recovers after query error", %{test_db: test_db} do
      {:ok, state} = EctoLibSql.connect(database: test_db)

      # Successful insert
      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO test_data (value) VALUES (?)",
          ["before"],
          [],
          state
        )

      # Force error (syntax)
      error_result = EctoLibSql.handle_execute("INVALID SQL", [], [], state)
      assert {:error, _reason, state} = error_result

      # Connection should still work
      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO test_data (value) VALUES (?)",
          ["after"],
          [],
          state
        )

      EctoLibSql.disconnect([], state)

      # Verify both successful inserts
      {:ok, state} = EctoLibSql.connect(database: test_db)

      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute("SELECT COUNT(*) FROM test_data", [], [], state)

      EctoLibSql.disconnect([], state)

      assert [[2]] = result.rows
    end

    test "multiple connections recover independently from errors", %{test_db: test_db} do
      tasks =
        Enum.map(1..3, fn i ->
          Task.async(fn ->
            {:ok, state} = EctoLibSql.connect(database: test_db)

            # Insert before error
            {:ok, _query, _result, state} =
              EctoLibSql.handle_execute(
                "INSERT INTO test_data (value) VALUES (?)",
                ["before_#{i}"],
                [],
                state
              )

            # Cause error
            EctoLibSql.handle_execute("BAD SQL", [], [], state)

            # Recovery insert
            result =
              EctoLibSql.handle_execute(
                "INSERT INTO test_data (value) VALUES (?)",
                ["after_#{i}"],
                [],
                state
              )

            EctoLibSql.disconnect([], state)
            result
          end)
        end)

      results = Task.await_many(tasks)

      # All recovery queries should succeed
      Enum.each(results, fn result ->
        assert {:ok, _query, _result, _state} = result
      end)

      # Verify all inserts
      {:ok, state} = EctoLibSql.connect(database: test_db)

      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute("SELECT COUNT(*) FROM test_data", [], [], state)

      EctoLibSql.disconnect([], state)

      # Should have 6 rows (3 before + 3 after)
      assert [[6]] = result.rows
    end
  end

  describe "resource cleanup under load" do
    test "prepared statements cleaned up under concurrent load", %{test_db: test_db} do
      tasks =
        Enum.map(1..5, fn i ->
          Task.async(fn ->
            {:ok, state} = EctoLibSql.connect(database: test_db)

            {:ok, stmt} =
              EctoLibSql.Native.prepare(
                state,
                "INSERT INTO test_data (value) VALUES (?)"
              )

            {:ok, _} =
              EctoLibSql.Native.execute_stmt(
                state,
                stmt,
                "INSERT INTO test_data (value) VALUES (?)",
                ["prep_#{i}"]
              )

            :ok = EctoLibSql.Native.close_stmt(stmt)

            EctoLibSql.disconnect([], state)
          end)
        end)

      Task.await_many(tasks)

      # Verify all inserts succeeded
      {:ok, state} = EctoLibSql.connect(database: test_db)

      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute("SELECT COUNT(*) FROM test_data", [], [], state)

      EctoLibSql.disconnect([], state)

      assert [[5]] = result.rows
    end
  end

  describe "transaction isolation" do
    test "concurrent transactions don't interfere with each other", %{test_db: test_db} do
      tasks =
        Enum.map(1..4, fn i ->
          Task.async(fn ->
            {:ok, state} = EctoLibSql.connect(database: test_db)

            {:ok, trx_state} = EctoLibSql.Native.begin(state)

            {:ok, _query, _result, trx_state} =
              EctoLibSql.handle_execute(
                "INSERT INTO test_data (value) VALUES (?)",
                ["iso_#{i}"],
                [],
                trx_state
              )

            # Slight delay to increase overlap
            Process.sleep(10)

            result = EctoLibSql.Native.commit(trx_state)

            EctoLibSql.disconnect([], state)
            result
          end)
        end)

      results = Task.await_many(tasks)

      # All should succeed
      Enum.each(results, fn result ->
        assert {:ok, _state} = result
      end)

      # All inserts should be visible
      {:ok, state} = EctoLibSql.connect(database: test_db)

      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute("SELECT COUNT(*) FROM test_data", [], [], state)

      EctoLibSql.disconnect([], state)

      assert [[4]] = result.rows
    end
  end
end
