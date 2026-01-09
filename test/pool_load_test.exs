defmodule EctoLibSql.PoolLoadTest do
  @moduledoc """
  Tests for concurrent connection behaviour under load.

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
      EctoLibSql.TestHelpers.cleanup_db_files(test_db)
    end)

    {:ok, test_db: test_db}
  end

  # ============================================================================
  # HELPER FUNCTIONS FOR EDGE CASE DATA
  # ============================================================================

  defp generate_edge_case_values(task_num) do
    [
      "normal_value_#{task_num}",         # Normal string
      nil,                                # NULL value
      "",                                  # Empty string
      String.duplicate("x", 1000),        # Large string (1KB)
      "special_chars_!@#$%^&*()_+-=[]{};" # Special characters
    ]
  end

  defp insert_edge_case_value(state, value) do
    EctoLibSql.handle_execute(
      "INSERT INTO test_data (value) VALUES (?)",
      [value],
      [],
      state
    )
  end

  describe "concurrent independent connections" do
    @tag :slow
    @tag :flaky
    test "multiple concurrent connections execute successfully", %{test_db: test_db} do
      # Spawn 5 concurrent connections
      tasks =
        Enum.map(1..5, fn i ->
          Task.async(fn ->
            {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

            try do
              EctoLibSql.handle_execute(
                "INSERT INTO test_data (value) VALUES (?)",
                ["task_#{i}"],
                [],
                state
              )
            after
              EctoLibSql.disconnect([], state)
            end
          end)
        end)

      # Wait for all to complete with extended timeout
      results = Task.await_many(tasks, 30_000)

      # All should succeed
      Enum.each(results, fn result ->
        assert {:ok, _query, _result, _state} = result
      end)

      # Verify all inserts succeeded
      {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute("SELECT COUNT(*) FROM test_data", [], [], state)

      EctoLibSql.disconnect([], state)

      assert [[5]] = result.rows
    end

    @tag :slow
    @tag :flaky
    test "rapid burst of concurrent connections succeeds", %{test_db: test_db} do
      # Fire 10 connections rapidly
      tasks =
        Enum.map(1..10, fn i ->
          Task.async(fn ->
            {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

            try do
              EctoLibSql.handle_execute(
                "INSERT INTO test_data (value) VALUES (?)",
                ["burst_#{i}"],
                [],
                state
              )
            after
              EctoLibSql.disconnect([], state)
            end
          end)
        end)

      results = Task.await_many(tasks, 30_000)

      # All should succeed
      success_count = Enum.count(results, fn r -> match?({:ok, _, _, _}, r) end)
      assert success_count == 10
    end

    @tag :slow
    @tag :flaky
    test "concurrent connections with edge-case data (NULL, empty, large values)", %{
      test_db: test_db
    } do
      # Spawn 5 concurrent connections, each inserting multiple edge-case values
      tasks =
        Enum.map(1..5, fn task_num ->
          Task.async(fn ->
            {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

            try do
              # Insert each edge-case value for this task
              edge_values = generate_edge_case_values(task_num)

              results =
                Enum.map(edge_values, fn value ->
                  insert_edge_case_value(state, value)
                end)

              # All inserts should succeed
              all_ok = Enum.all?(results, fn r -> match?({:ok, _, _, _}, r) end)
              if all_ok, do: {:ok, :all_edge_cases_inserted}, else: {:error, :some_inserts_failed}
            after
              EctoLibSql.disconnect([], state)
            end
          end)
        end)

      results = Task.await_many(tasks, 30_000)

      # All edge-case inserts should succeed
      Enum.each(results, fn result ->
        assert {:ok, :all_edge_cases_inserted} = result
      end)

      # Verify all inserts: 5 tasks × 5 edge cases = 25 rows
      {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute("SELECT COUNT(*) FROM test_data", [], [], state)

      EctoLibSql.disconnect([], state)

      assert [[25]] = result.rows

      # Verify we can read back the NULL values and empty strings
      {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

      {:ok, _query, null_result, _state} =
        EctoLibSql.handle_execute(
          "SELECT COUNT(*) FROM test_data WHERE value IS NULL",
          [],
          [],
          state
        )

      {:ok, _query, empty_result, _state} =
        EctoLibSql.handle_execute(
          "SELECT COUNT(*) FROM test_data WHERE value = ''",
          [],
          [],
          state
        )

      EctoLibSql.disconnect([], state)

      # Should have 5 NULL values (one per task)
      assert [[5]] = null_result.rows
      # Should have 5 empty strings (one per task)
      assert [[5]] = empty_result.rows
      end
      end

      describe "long-running operations" do
    @tag :slow
    @tag :flaky
    test "long transaction doesn't cause timeout issues", %{test_db: test_db} do
      {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 5000)

      try do
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
      after
        EctoLibSql.disconnect([], state)
      end
    end

    @tag :slow
    @tag :flaky
    test "multiple concurrent transactions complete despite duration", %{test_db: test_db} do
      tasks =
        Enum.map(1..3, fn i ->
          Task.async(fn ->
            {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

            try do
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

              # Explicitly handle commit result to catch errors
              case EctoLibSql.Native.commit(trx_state) do
                {:ok, _committed_state} ->
                  {:ok, :committed}

                {:error, reason} ->
                  {:error, {:commit_failed, reason}}
              end
            after
              EctoLibSql.disconnect([], state)
            end
          end)
        end)

      results = Task.await_many(tasks, 30_000)

      # All commits should succeed; fail test if any error occurred
      Enum.each(results, fn result ->
        case result do
          {:ok, :committed} ->
            :ok

          {:error, {:commit_failed, reason}} ->
            flunk("Transaction commit failed: #{inspect(reason)}")

          other ->
            flunk("Unexpected result from concurrent transaction: #{inspect(other)}")
        end
      end)

      # Verify all inserts
      {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute("SELECT COUNT(*) FROM test_data", [], [], state)

      EctoLibSql.disconnect([], state)

      assert [[3]] = result.rows
    end
  end

  describe "connection recovery" do
    @tag :slow
    @tag :flaky
    test "connection recovers after query error", %{test_db: test_db} do
      {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

      try do
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
        assert {:error, _reason, ^state} = error_result

        # Connection should still work
        {:ok, _query, _result, ^state} =
          EctoLibSql.handle_execute(
            "INSERT INTO test_data (value) VALUES (?)",
            ["after"],
            [],
            state
          )
      after
        EctoLibSql.disconnect([], state)
      end

      # Verify both successful inserts
      {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

      try do
        {:ok, _query, result, _state} =
          EctoLibSql.handle_execute("SELECT COUNT(*) FROM test_data", [], [], state)

        assert [[2]] = result.rows
      after
        EctoLibSql.disconnect([], state)
      end
    end

    @tag :slow
    @tag :flaky
    test "multiple connections recover independently from errors", %{test_db: test_db} do
      tasks =
        Enum.map(1..3, fn i ->
          Task.async(fn ->
            {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

            try do
              # Insert before error
              {:ok, _query, _result, state} =
                EctoLibSql.handle_execute(
                  "INSERT INTO test_data (value) VALUES (?)",
                  ["before_#{i}"],
                  [],
                  state
                )

              # Cause error (intentionally ignore it to test recovery)
              # Discard error state - next operation uses original state
              error_result = EctoLibSql.handle_execute("BAD SQL", [], [], state)
              assert {:error, _reason, _state} = error_result

              # Recovery insert - verify it succeeds
              case EctoLibSql.handle_execute(
                     "INSERT INTO test_data (value) VALUES (?)",
                     ["after_#{i}"],
                     [],
                     state
                   ) do
                {:ok, _query, _result, _state} ->
                  {:ok, :recovered}

                {:error, reason, _state} ->
                  {:error, {:recovery_failed, reason}}
              end
            after
              EctoLibSql.disconnect([], state)
            end
          end)
        end)

      results = Task.await_many(tasks, 30_000)

      # All recovery queries should succeed
      Enum.each(results, fn result ->
        case result do
          {:ok, :recovered} ->
            :ok

          {:error, {:recovery_failed, reason}} ->
            flunk("Connection recovery insert failed: #{inspect(reason)}")

          other ->
            flunk("Unexpected result from connection recovery task: #{inspect(other)}")
        end
      end)

      # Verify all inserts
      {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute("SELECT COUNT(*) FROM test_data", [], [], state)

      EctoLibSql.disconnect([], state)

      # Should have 6 rows (3 before + 3 after)
      assert [[6]] = result.rows
    end
  end

  describe "resource cleanup under load" do
    @tag :slow
    @tag :flaky
    test "prepared statements cleaned up under concurrent load", %{test_db: test_db} do
      tasks =
        Enum.map(1..5, fn i ->
          Task.async(fn ->
            {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

            try do
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
              {:ok, :prepared_and_cleaned}
            after
              EctoLibSql.disconnect([], state)
            end
          end)
        end)

      results = Task.await_many(tasks, 30_000)

      # Verify all prepared statement operations succeeded
      Enum.each(results, fn result ->
        case result do
          {:ok, :prepared_and_cleaned} ->
            :ok

          {:error, reason} ->
            flunk("Prepared statement operation failed: #{inspect(reason)}")

          other ->
            flunk("Unexpected result from prepared statement task: #{inspect(other)}")
        end
      end)

      # Verify all inserts succeeded
      {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute("SELECT COUNT(*) FROM test_data", [], [], state)

      EctoLibSql.disconnect([], state)

      assert [[5]] = result.rows
    end
  end

  describe "transaction isolation" do
     @tag :slow
     @tag :flaky
     test "concurrent transactions don't interfere with each other", %{test_db: test_db} do
       tasks =
         Enum.map(1..4, fn i ->
           Task.async(fn ->
             {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

             try do
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

               # Explicitly handle commit result to catch errors
               case EctoLibSql.Native.commit(trx_state) do
                 {:ok, _committed_state} ->
                   {:ok, :committed}

                 {:error, reason} ->
                   {:error, {:commit_failed, reason}}
               end
             after
               EctoLibSql.disconnect([], state)
             end
           end)
         end)

       results = Task.await_many(tasks, 30_000)

       # All commits should succeed; fail test if any error occurred
       Enum.each(results, fn result ->
         case result do
           {:ok, :committed} ->
             :ok

           {:error, {:commit_failed, reason}} ->
             flunk("Concurrent transaction commit failed: #{inspect(reason)}")

           other ->
             flunk("Unexpected result from concurrent transaction: #{inspect(other)}")
         end
       end)

       # All inserts should be visible
       {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

       {:ok, _query, result, _state} =
         EctoLibSql.handle_execute("SELECT COUNT(*) FROM test_data", [], [], state)

       EctoLibSql.disconnect([], state)

       assert [[4]] = result.rows
     end

     @tag :slow
     @tag :flaky
     test "concurrent transactions with edge-case data maintain isolation", %{test_db: test_db} do
       # Each task inserts edge-case values in a transaction
       tasks =
         Enum.map(1..4, fn task_num ->
           Task.async(fn ->
             {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

             try do
               {:ok, trx_state} = EctoLibSql.Native.begin(state)

               # Insert edge-case values within transaction
               edge_values = generate_edge_case_values(task_num)

               insert_results =
                 Enum.map(edge_values, fn value ->
                   {:ok, _query, _result, new_state} = insert_edge_case_value(trx_state, value)
                   new_state
                 end)

               # Use final state after all inserts
               final_trx_state = List.last(insert_results) || trx_state

               # Slight delay to increase overlap with other transactions
               Process.sleep(10)

               # Commit the transaction containing all edge-case values
               case EctoLibSql.Native.commit(final_trx_state) do
                 {:ok, _committed_state} ->
                   {:ok, :committed_with_edge_cases}

                 {:error, reason} ->
                   {:error, {:commit_failed, reason}}
               end
             after
               EctoLibSql.disconnect([], state)
             end
           end)
         end)

       results = Task.await_many(tasks, 30_000)

       # All commits should succeed
       Enum.each(results, fn result ->
         case result do
           {:ok, :committed_with_edge_cases} ->
             :ok

           {:error, {:commit_failed, reason}} ->
             flunk("Edge-case transaction commit failed: #{inspect(reason)}")

           other ->
             flunk("Unexpected result from edge-case transaction: #{inspect(other)}")
         end
       end)

       # Verify all edge-case data was inserted: 4 tasks × 5 edge cases = 20 rows
       {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

       {:ok, _query, result, _state} =
         EctoLibSql.handle_execute("SELECT COUNT(*) FROM test_data", [], [], state)

       EctoLibSql.disconnect([], state)

       assert [[20]] = result.rows

       # Verify NULL values survived transaction boundaries
       {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

       {:ok, _query, null_result, _state} =
         EctoLibSql.handle_execute(
           "SELECT COUNT(*) FROM test_data WHERE value IS NULL",
           [],
           [],
           state
         )

       EctoLibSql.disconnect([], state)

       # Should have 4 NULL values (one per task)
       assert [[4]] = null_result.rows
     end
   end
end
