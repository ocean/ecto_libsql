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

    {:ok, _query, _result, state} =
      EctoLibSql.handle_execute(
        "CREATE TABLE test_data (id INTEGER PRIMARY KEY AUTOINCREMENT, value TEXT, duration INTEGER)",
        [],
        [],
        state
      )

    # Capture conn_id for reliable cleanup
    conn_id = state.conn_id

    on_exit(fn ->
      EctoLibSql.disconnect([], %EctoLibSql.State{conn_id: conn_id})
      EctoLibSql.TestHelpers.cleanup_db_files(test_db)
    end)

    {:ok, test_db: test_db}
  end

  # ============================================================================
  # HELPER FUNCTIONS FOR EDGE CASE DATA
  # ============================================================================

  defp generate_edge_case_values(task_num) do
    [
      # Normal string
      "normal_value_#{task_num}",
      # NULL value
      nil,
      # Empty string
      "",
      # Large string (1KB)
      String.duplicate("x", 1000),
      # Special characters
      "special_chars_!@#$%^&*()_+-=[]{};"
    ]
  end

  defp generate_unicode_edge_case_values(task_num) do
    [
      # Latin with accents (ê, á, ü)
      "café_#{task_num}",
      # Chinese characters (中文)
      "chinese_中文_#{task_num}",
      # Arabic characters (العربية)
      "arabic_العربية_#{task_num}",
      # Emoji (😀, 🎉, ❤️)
      "emoji_😀🎉❤️_#{task_num}",
      # Mixed: combining all above
      "mixed_café_中文_العربية_😀_#{task_num}"
    ]
  end

  defp insert_unicode_edge_case_value(state, value) do
    EctoLibSql.handle_execute(
      "INSERT INTO test_data (value) VALUES (?)",
      [value],
      [],
      state
    )
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

    @tag :slow
    @tag :flaky
    test "concurrent connections with unicode data (Chinese, Arabic, emoji)", %{
      test_db: test_db
    } do
      # Clean the table first (other tests may have added data)
      {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

      {:ok, _, _, state} =
        EctoLibSql.handle_execute("DELETE FROM test_data", [], [], state)

      EctoLibSql.disconnect([], state)

      # Spawn 5 concurrent connections, each inserting Unicode values
      tasks =
        Enum.map(1..5, fn task_num ->
          Task.async(fn ->
            {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

            try do
              # Insert each Unicode value for this task
              unicode_values = generate_unicode_edge_case_values(task_num)

              results =
                Enum.map(unicode_values, fn value ->
                  insert_unicode_edge_case_value(state, value)
                end)

              # All inserts should succeed
              all_ok = Enum.all?(results, fn r -> match?({:ok, _, _, _}, r) end)

              if all_ok,
                do: {:ok, :all_unicode_inserted},
                else: {:error, :some_unicode_inserts_failed}
            after
              EctoLibSql.disconnect([], state)
            end
          end)
        end)

      results = Task.await_many(tasks, 30_000)

      # All Unicode inserts should succeed
      Enum.each(results, fn result ->
        assert {:ok, :all_unicode_inserted} = result
      end)

      # Verify all inserts: 5 tasks × 5 Unicode values = 25 rows
      {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute("SELECT COUNT(*) FROM test_data", [], [], state)

      EctoLibSql.disconnect([], state)

      assert [[25]] = result.rows

      # Verify Unicode characters are correctly preserved by reading back specific values
      {:ok, state2} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

      {:ok, _query, all_rows_result, _state} =
        EctoLibSql.handle_execute("SELECT value FROM test_data", [], [], state2)

      EctoLibSql.disconnect([], state2)

      values = Enum.map(all_rows_result.rows, fn [v] -> v end)

      # Verify specific Unicode patterns are preserved (5 tasks, each pattern appears 5 times)
      assert Enum.count(values, &String.contains?(&1, "café")) == 5
      assert Enum.count(values, &String.contains?(&1, "中文")) == 5
      assert Enum.count(values, &String.contains?(&1, "العربية")) == 5
      assert Enum.count(values, &String.contains?(&1, "😀🎉❤️")) == 5
      assert Enum.count(values, &String.contains?(&1, "mixed_")) == 5
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
    test "connection recovery with edge-case data (NULL, empty, large values)", %{
      test_db: test_db
    } do
      {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

      try do
        # Insert edge-case data before error
        edge_values = generate_edge_case_values(1)

        Enum.each(edge_values, fn value ->
          insert_edge_case_value(state, value)
        end)

        # Cause error
        error_result = EctoLibSql.handle_execute("MALFORMED SQL HERE", [], [], state)
        assert {:error, _reason, ^state} = error_result

        # Insert more edge-case data after error to verify recovery
        edge_values_2 = generate_edge_case_values(2)

        insert_results =
          Enum.map(edge_values_2, fn value ->
            insert_edge_case_value(state, value)
          end)

        # All inserts should succeed
        all_ok = Enum.all?(insert_results, fn r -> match?({:ok, _, _, _}, r) end)
        assert all_ok
      after
        EctoLibSql.disconnect([], state)
      end

      # Verify all edge-case data persisted
      {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

      try do
        {:ok, _query, result, _state} =
          EctoLibSql.handle_execute("SELECT COUNT(*) FROM test_data", [], [], state)

        # Should have 10 rows (5 before error + 5 after)
        assert [[10]] = result.rows

        # Verify NULL values
        {:ok, _query, null_result, _state} =
          EctoLibSql.handle_execute(
            "SELECT COUNT(*) FROM test_data WHERE value IS NULL",
            [],
            [],
            state
          )

        # Should have 2 NULL values
        assert [[2]] = null_result.rows
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

              try do
                {:ok, _} =
                  EctoLibSql.Native.execute_stmt(
                    state,
                    stmt,
                    "INSERT INTO test_data (value) VALUES (?)",
                    ["prep_#{i}"]
                  )

                {:ok, :prepared_and_cleaned}
              after
                # Always close the prepared statement, ignore errors
                try do
                  EctoLibSql.Native.close_stmt(stmt)
                rescue
                  _ -> :ok
                end
              end
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

    @tag :slow
    @tag :flaky
    test "prepared statements with edge-case data cleaned up correctly", %{
      test_db: test_db
    } do
      tasks =
        Enum.map(1..5, fn task_num ->
          Task.async(fn ->
            {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

            try do
              {:ok, stmt} =
                EctoLibSql.Native.prepare(
                  state,
                  "INSERT INTO test_data (value) VALUES (?)"
                )

              try do
                # Execute prepared statement with edge-case data
                edge_values = generate_edge_case_values(task_num)

                execute_results =
                  Enum.map(edge_values, fn value ->
                    EctoLibSql.Native.execute_stmt(
                      state,
                      stmt,
                      "INSERT INTO test_data (value) VALUES (?)",
                      [value]
                    )
                  end)

                # All executions should succeed
                all_ok = Enum.all?(execute_results, fn r -> match?({:ok, _}, r) end)

                if all_ok do
                  {:ok, :prepared_with_edge_cases}
                else
                  {:error, :some_edge_case_inserts_failed}
                end
              after
                # Always close the prepared statement, ignore errors
                try do
                  EctoLibSql.Native.close_stmt(stmt)
                rescue
                  _ -> :ok
                end
              end
            after
              EctoLibSql.disconnect([], state)
            end
          end)
        end)

      results = Task.await_many(tasks, 30_000)

      # Verify all prepared statement operations succeeded
      Enum.each(results, fn result ->
        case result do
          {:ok, :prepared_with_edge_cases} ->
            :ok

          {:error, reason} ->
            flunk("Prepared statement with edge-case data failed: #{inspect(reason)}")

          other ->
            flunk("Unexpected result from prepared statement edge-case task: #{inspect(other)}")
        end
      end)

      # Verify all inserts succeeded: 5 tasks × 5 edge cases = 25 rows
      {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

      try do
        {:ok, _query, result, _state} =
          EctoLibSql.handle_execute("SELECT COUNT(*) FROM test_data", [], [], state)

        assert [[25]] = result.rows

        # Verify NULL values exist
        {:ok, _query, null_result, _state} =
          EctoLibSql.handle_execute(
            "SELECT COUNT(*) FROM test_data WHERE value IS NULL",
            [],
            [],
            state
          )

        # Should have 5 NULL values (one per task)
        assert [[5]] = null_result.rows
      after
        EctoLibSql.disconnect([], state)
      end
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

              # Insert edge-case values within transaction, threading state through
              edge_values = generate_edge_case_values(task_num)

              final_trx_state =
                Enum.reduce(edge_values, trx_state, fn value, acc_state ->
                  {:ok, _query, _result, new_state} = insert_edge_case_value(acc_state, value)
                  new_state
                end)

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

  describe "concurrent load edge cases" do
    @tag :slow
    @tag :flaky
    test "concurrent load with only NULL values", %{test_db: test_db} do
      tasks =
        Enum.map(1..10, fn _i ->
          Task.async(fn ->
            {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

            try do
              EctoLibSql.handle_execute(
                "INSERT INTO test_data (value, duration) VALUES (?, ?)",
                [nil, nil],
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
      Enum.each(results, fn result ->
        assert {:ok, _query, _result, _state} = result
      end)

      # Verify all NULL inserts
      {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute(
          "SELECT COUNT(*) FROM test_data WHERE value IS NULL AND duration IS NULL",
          [],
          [],
          state
        )

      EctoLibSql.disconnect([], state)
      assert [[10]] = result.rows
    end

    @tag :slow
    @tag :flaky
    test "concurrent load with only empty strings", %{test_db: test_db} do
      tasks =
        Enum.map(1..10, fn _i ->
          Task.async(fn ->
            {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

            try do
              EctoLibSql.handle_execute(
                "INSERT INTO test_data (value) VALUES (?)",
                [""],
                [],
                state
              )
            after
              EctoLibSql.disconnect([], state)
            end
          end)
        end)

      results = Task.await_many(tasks, 30_000)

      Enum.each(results, fn result ->
        assert {:ok, _query, _result, _state} = result
      end)

      # Verify empty strings (not NULL)
      {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

      {:ok, _query, empty_result, _state} =
        EctoLibSql.handle_execute(
          "SELECT COUNT(*) FROM test_data WHERE value = ''",
          [],
          [],
          state
        )

      {:ok, _query, null_result, _state} =
        EctoLibSql.handle_execute(
          "SELECT COUNT(*) FROM test_data WHERE value IS NULL",
          [],
          [],
          state
        )

      EctoLibSql.disconnect([], state)

      assert [[10]] = empty_result.rows
      assert [[0]] = null_result.rows
    end

    @tag :slow
    @tag :flaky
    test "concurrent load large dataset (100 rows per connection)", %{test_db: test_db} do
      tasks =
        Enum.map(1..5, fn task_num ->
          Task.async(fn ->
            {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 60_000)

            try do
              # Insert 100 rows per task
              results =
                Enum.map(1..100, fn row_num ->
                  EctoLibSql.handle_execute(
                    "INSERT INTO test_data (value, duration) VALUES (?, ?)",
                    ["task_#{task_num}_row_#{row_num}", task_num * 100 + row_num],
                    [],
                    state
                  )
                end)

              all_ok = Enum.all?(results, fn r -> match?({:ok, _, _, _}, r) end)
              if all_ok, do: {:ok, 100}, else: {:error, :some_failed}
            after
              EctoLibSql.disconnect([], state)
            end
          end)
        end)

      results = Task.await_many(tasks, 60_000)

      # All tasks should succeed
      Enum.each(results, fn result ->
        assert {:ok, 100} = result
      end)

      # Verify total row count: 5 tasks × 100 rows = 500
      {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute("SELECT COUNT(*) FROM test_data", [], [], state)

      EctoLibSql.disconnect([], state)
      assert [[500]] = result.rows
    end

    @tag :slow
    @tag :flaky
    test "concurrent load with type conversion (ints, floats, strings)", %{test_db: test_db} do
      # Add columns for different types
      {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

      {:ok, _query, _result, _state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE typed_data (id INTEGER PRIMARY KEY AUTOINCREMENT, int_val INTEGER, float_val REAL, text_val TEXT, timestamp_val TEXT)",
          [],
          [],
          state
        )

      EctoLibSql.disconnect([], state)

      tasks =
        Enum.map(1..5, fn task_num ->
          Task.async(fn ->
            {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

            try do
              now = DateTime.utc_now() |> DateTime.to_iso8601()

              results = [
                # Integer values
                EctoLibSql.handle_execute(
                  "INSERT INTO typed_data (int_val, float_val, text_val, timestamp_val) VALUES (?, ?, ?, ?)",
                  [task_num * 1000, task_num * 1.5, "text_#{task_num}", now],
                  [],
                  state
                ),
                # Negative integer
                EctoLibSql.handle_execute(
                  "INSERT INTO typed_data (int_val, float_val, text_val, timestamp_val) VALUES (?, ?, ?, ?)",
                  [-task_num, -task_num * 0.5, "negative_#{task_num}", now],
                  [],
                  state
                ),
                # Zero values
                EctoLibSql.handle_execute(
                  "INSERT INTO typed_data (int_val, float_val, text_val, timestamp_val) VALUES (?, ?, ?, ?)",
                  [0, 0.0, "", now],
                  [],
                  state
                ),
                # Large integer
                EctoLibSql.handle_execute(
                  "INSERT INTO typed_data (int_val, float_val, text_val, timestamp_val) VALUES (?, ?, ?, ?)",
                  [9_223_372_036_854_775_807, 1.7976931348623157e308, "max_#{task_num}", now],
                  [],
                  state
                )
              ]

              all_ok = Enum.all?(results, fn r -> match?({:ok, _, _, _}, r) end)
              if all_ok, do: {:ok, :types_inserted}, else: {:error, :type_insert_failed}
            after
              EctoLibSql.disconnect([], state)
            end
          end)
        end)

      results = Task.await_many(tasks, 30_000)

      Enum.each(results, fn result ->
        assert {:ok, :types_inserted} = result
      end)

      # Verify type preservation
      {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute(
          "SELECT int_val, float_val, text_val FROM typed_data WHERE int_val = 0 LIMIT 1",
          [],
          [],
          state
        )

      EctoLibSql.disconnect([], state)

      [[int_val, float_val, text_val]] = result.rows
      assert int_val == 0
      assert float_val == 0.0
      assert text_val == ""
    end
  end

  describe "transaction rollback under load" do
    @tag :slow
    @tag :flaky
    test "concurrent transaction rollback leaves no data", %{test_db: test_db} do
      # Clear any existing data
      {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)
      EctoLibSql.handle_execute("DELETE FROM test_data", [], [], state)
      EctoLibSql.disconnect([], state)

      tasks =
        Enum.map(1..5, fn task_num ->
          Task.async(fn ->
            {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

            try do
              # Begin transaction
              {:ok, trx_state} = EctoLibSql.Native.begin(state)

              # Insert some data
              {:ok, _query, _result, trx_state} =
                EctoLibSql.handle_execute(
                  "INSERT INTO test_data (value) VALUES (?)",
                  ["rollback_test_#{task_num}"],
                  [],
                  trx_state
                )

              # Always rollback - data should not persist
              case EctoLibSql.Native.rollback(trx_state) do
                {:ok, _state} ->
                  {:ok, :rolled_back}

                {:error, reason} ->
                  {:error, {:rollback_failed, reason}}
              end
            after
              EctoLibSql.disconnect([], state)
            end
          end)
        end)

      results = Task.await_many(tasks, 30_000)

      # All rollbacks should succeed
      Enum.each(results, fn result ->
        assert {:ok, :rolled_back} = result
      end)

      # Verify no data persisted
      {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute("SELECT COUNT(*) FROM test_data", [], [], state)

      EctoLibSql.disconnect([], state)

      assert [[0]] = result.rows
    end

    @tag :slow
    @tag :flaky
    test "mixed commit and rollback transactions maintain consistency", %{test_db: test_db} do
      # Clear any existing data
      {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)
      EctoLibSql.handle_execute("DELETE FROM test_data", [], [], state)
      EctoLibSql.disconnect([], state)

      # Even tasks commit, odd tasks rollback
      tasks =
        Enum.map(1..10, fn task_num ->
          Task.async(fn ->
            {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

            try do
              {:ok, trx_state} = EctoLibSql.Native.begin(state)

              {:ok, _query, _result, trx_state} =
                EctoLibSql.handle_execute(
                  "INSERT INTO test_data (value) VALUES (?)",
                  ["task_#{task_num}"],
                  [],
                  trx_state
                )

              Process.sleep(5)

              if rem(task_num, 2) == 0 do
                # Even tasks commit
                case EctoLibSql.Native.commit(trx_state) do
                  {:ok, _state} -> {:ok, :committed}
                  {:error, reason} -> {:error, {:commit_failed, reason}}
                end
              else
                # Odd tasks rollback
                case EctoLibSql.Native.rollback(trx_state) do
                  {:ok, _state} -> {:ok, :rolled_back}
                  {:error, reason} -> {:error, {:rollback_failed, reason}}
                end
              end
            after
              EctoLibSql.disconnect([], state)
            end
          end)
        end)

      results = Task.await_many(tasks, 30_000)

      # Count commits and rollbacks
      commits = Enum.count(results, fn r -> r == {:ok, :committed} end)
      rollbacks = Enum.count(results, fn r -> r == {:ok, :rolled_back} end)

      assert commits == 5, "Should have 5 committed transactions"
      assert rollbacks == 5, "Should have 5 rolled back transactions"

      # Verify only committed data exists (5 rows)
      {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute("SELECT COUNT(*) FROM test_data", [], [], state)

      EctoLibSql.disconnect([], state)

      assert [[5]] = result.rows
    end

    @tag :slow
    @tag :flaky
    test "transaction rollback after intentional constraint violation", %{test_db: test_db} do
      # Create table with unique constraint
      {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

      {:ok, _query, _result, _state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE unique_test (id INTEGER PRIMARY KEY, unique_val TEXT UNIQUE)",
          [],
          [],
          state
        )

      # Insert initial row
      {:ok, _query, _result, _state} =
        EctoLibSql.handle_execute(
          "INSERT INTO unique_test (unique_val) VALUES (?)",
          ["existing_value"],
          [],
          state
        )

      EctoLibSql.disconnect([], state)

      tasks =
        Enum.map(1..5, fn task_num ->
          Task.async(fn ->
            {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

            try do
              {:ok, trx_state} = EctoLibSql.Native.begin(state)

              # Insert valid row
              {:ok, _query, _result, trx_state} =
                EctoLibSql.handle_execute(
                  "INSERT INTO unique_test (unique_val) VALUES (?)",
                  ["task_#{task_num}_valid"],
                  [],
                  trx_state
                )

              # Try to insert duplicate - should fail
              result =
                EctoLibSql.handle_execute(
                  "INSERT INTO unique_test (unique_val) VALUES (?)",
                  ["existing_value"],
                  [],
                  trx_state
                )

              case result do
                {:error, _reason, trx_state} ->
                  # Expected: constraint violation
                  EctoLibSql.Native.rollback(trx_state)
                  {:ok, :correctly_rolled_back}

                {:ok, _query, _result, trx_state} ->
                  # Unexpected: should have failed
                  EctoLibSql.Native.rollback(trx_state)
                  {:error, :should_have_failed}
              end
            after
              EctoLibSql.disconnect([], state)
            end
          end)
        end)

      results = Task.await_many(tasks, 30_000)

      # All should have rolled back due to constraint violation
      Enum.each(results, fn result ->
        assert {:ok, :correctly_rolled_back} = result
      end)

      # Verify only original row exists
      {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute("SELECT COUNT(*) FROM unique_test", [], [], state)

      EctoLibSql.disconnect([], state)

      # Only the initial "existing_value" row should exist
      assert [[1]] = result.rows
    end

    @tag :slow
    @tag :flaky
    test "concurrent transactions with edge-case data and rollback", %{test_db: test_db} do
      # Clear table
      {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)
      EctoLibSql.handle_execute("DELETE FROM test_data", [], [], state)
      EctoLibSql.disconnect([], state)

      tasks =
        Enum.map(1..5, fn task_num ->
          Task.async(fn ->
            {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

            try do
              {:ok, trx_state} = EctoLibSql.Native.begin(state)

              # Insert edge-case values in transaction, threading state through
              edge_values = generate_edge_case_values(task_num)

              final_trx_state =
                Enum.reduce(edge_values, trx_state, fn value, acc_state ->
                  {:ok, _query, _result, new_state} = insert_edge_case_value(acc_state, value)
                  new_state
                end)

              # Always rollback - edge-case data should not persist
              case EctoLibSql.Native.rollback(final_trx_state) do
                {:ok, _state} ->
                  {:ok, :edge_cases_rolled_back}

                {:error, reason} ->
                  {:error, {:rollback_failed, reason}}
              end
            after
              EctoLibSql.disconnect([], state)
            end
          end)
        end)

      results = Task.await_many(tasks, 30_000)

      # All rollbacks should succeed
      Enum.each(results, fn result ->
        assert {:ok, :edge_cases_rolled_back} = result
      end)

      # Verify no data persisted
      {:ok, state} = EctoLibSql.connect(database: test_db, busy_timeout: 30_000)

      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute("SELECT COUNT(*) FROM test_data", [], [], state)

      EctoLibSql.disconnect([], state)

      assert [[0]] = result.rows
    end
  end
end
