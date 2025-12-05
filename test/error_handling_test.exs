defmodule EctoLibSql.ErrorHandlingTest do
  use ExUnit.Case

  @moduledoc """
  Tests that demonstrate graceful error handling that would have caused
  VM crashes before the unwrap() elimination refactoring.

  These tests verify that Rust NIF errors are properly returned to Elixir
  rather than panicking and crashing the BEAM VM.
  """

  describe "invalid connection ID handling" do
    test "query with non-existent connection ID returns error (not panic)" do
      # Before: This would have called .unwrap() on None and panicked the VM
      # After: Returns a proper error tuple to Elixir

      fake_conn_id = "00000000-0000-0000-0000-000000000000"
      result = EctoLibSql.Native.query_args(fake_conn_id, :local, :disable_sync, "SELECT 1", [])

      assert {:error, error_msg} = result
      assert error_msg =~ "Invalid connection" or error_msg =~ "Connection"
    end

    test "ping with invalid connection returns error (not panic)" do
      # Before: Would panic on unwrap() when connection not found
      # After: Returns error tuple

      fake_conn_id = "invalid-connection-id"

      result = EctoLibSql.Native.ping(fake_conn_id)

      assert {:error, error_msg} = result
      assert error_msg =~ "Connection" or error_msg =~ "Invalid"
    end

    test "close with invalid connection returns error (not panic)" do
      # Before: Would unwrap() None when connection not in registry
      # After: Returns proper error

      fake_id = "nonexistent-connection"

      result = EctoLibSql.Native.close(fake_id, :conn_id)

      assert {:error, error_msg} = result
      assert error_msg =~ "Connection not found"
    end
  end

  describe "invalid transaction ID handling" do
    test "commit with non-existent transaction returns error (not panic)" do
      # Before: .unwrap() on None would panic
      # After: Returns error tuple

      fake_conn_id = "fake-conn"
      fake_trx_id = "00000000-0000-0000-0000-000000000000"

      result =
        EctoLibSql.Native.commit_or_rollback_transaction(
          fake_trx_id,
          fake_conn_id,
          :local,
          :disable_sync,
          "commit"
        )

      assert {:error, error_msg} = result
      assert error_msg =~ "Transaction not found"
    end

    test "rollback with non-existent transaction returns error (not panic)" do
      fake_conn_id = "fake-conn"
      fake_trx_id = "invalid-transaction"

      result =
        EctoLibSql.Native.commit_or_rollback_transaction(
          fake_trx_id,
          fake_conn_id,
          :local,
          :disable_sync,
          "rollback"
        )

      assert {:error, error_msg} = result
      assert error_msg =~ "Transaction not found"
    end

    test "execute with invalid transaction returns error (not panic)" do
      fake_trx_id = "nonexistent-transaction"
      fake_conn_id = "nonexistent-connection"

      result =
        EctoLibSql.Native.execute_with_transaction(
          fake_trx_id,
          fake_conn_id,
          "INSERT INTO test VALUES (1)",
          []
        )

      assert {:error, error_msg} = result
      assert error_msg =~ "Transaction not found"
    end
  end

  describe "invalid statement ID handling" do
    test "query with non-existent prepared statement returns error (not panic)" do
      # Before: Would unwrap() None when statement not in registry
      # After: Returns proper error

      fake_conn_id = "fake-conn"
      fake_stmt_id = "nonexistent-statement"

      result =
        EctoLibSql.Native.query_prepared(
          fake_conn_id,
          fake_stmt_id,
          :local,
          :disable_sync,
          []
        )

      assert {:error, error_msg} = result
      assert error_msg =~ "Statement not found" or error_msg =~ "Invalid"
    end

    test "execute with non-existent prepared statement returns error (not panic)" do
      fake_conn_id = "fake-conn"
      fake_stmt_id = "invalid-stmt"

      result =
        EctoLibSql.Native.execute_prepared(
          fake_conn_id,
          fake_stmt_id,
          :local,
          :disable_sync,
          "INSERT INTO test VALUES (1)",
          []
        )

      assert {:error, error_msg} = result
      assert error_msg =~ "Statement not found" or error_msg =~ "Invalid"
    end

    test "close with invalid statement returns error (not panic)" do
      fake_stmt_id = "nonexistent-statement"

      result = EctoLibSql.Native.close(fake_stmt_id, :stmt_id)

      assert {:error, error_msg} = result
      assert error_msg =~ "Statement not found"
    end
  end

  describe "invalid cursor ID handling" do
    test "fetch with non-existent cursor returns error (not panic)" do
      # Before: Would unwrap() None when cursor not in registry
      # After: Returns proper error

      fake_conn_id = "nonexistent-connection"
      fake_cursor_id = "nonexistent-cursor"

      result = EctoLibSql.Native.fetch_cursor(fake_conn_id, fake_cursor_id, 100)

      assert {:error, error_msg} = result
      assert error_msg =~ "Cursor not found"
    end

    test "close with invalid cursor returns error (not panic)" do
      fake_cursor_id = "invalid-cursor"

      result = EctoLibSql.Native.close(fake_cursor_id, :cursor_id)

      assert {:error, error_msg} = result
      assert error_msg =~ "Cursor not found"
    end
  end

  describe "concurrent access and mutex safety" do
    @tag :skip
    test "concurrent operations don't cause mutex poisoning crashes" do
      # This test demonstrates that even under concurrent stress,
      # mutex errors are handled gracefully rather than poisoning
      # and cascading to VM crash

      # Create a real connection for some tasks
      test_db = "test_concurrent_#{:erlang.unique_integer([:positive])}.db"
      opts = [database: test_db, sync: false]
      {:ok, state} = EctoLibSql.connect(opts)
      real_conn_id = state.conn_id

      # Spawn many concurrent tasks mixing valid and invalid operations
      tasks =
        Enum.map(1..50, fn i ->
          Task.async(fn ->
            case rem(i, 3) do
              0 ->
                # Valid operation
                EctoLibSql.Native.ping(real_conn_id)

              1 ->
                # Invalid connection
                EctoLibSql.Native.ping("invalid-#{i}")

              2 ->
                # Invalid transaction
                EctoLibSql.Native.execute_with_transaction("invalid-trx-#{i}", "SELECT 1", [])
            end
          end)
        end)

      # All tasks should complete without crashing the VM
      results = Task.await_many(tasks, 5000)

      # Some should succeed, some should fail, but none should crash
      assert length(results) == 50

      # Cleanup
      EctoLibSql.Native.close(real_conn_id, :conn_id)
      File.rm(test_db)
    end
  end

  describe "error message quality" do
    test "error messages include helpful context" do
      # The new error handling provides context about what failed
      fake_conn_id = "test-connection-id"

      result =
        EctoLibSql.Native.query_args(
          fake_conn_id,
          :local,
          :disable_sync,
          "SELECT 1",
          []
        )

      assert {:error, error_msg} = result

      # Error message should be descriptive
      assert is_binary(error_msg)
      assert String.length(error_msg) > 10
    end
  end

  describe "error recovery in supervision tree" do
    test "process can recover from NIF errors via supervision" do
      # Demonstrate that errors are returned to the process,
      # allowing supervision strategies to work properly

      parent = self()

      # Spawn a process that will call the NIF
      pid =
        spawn(fn ->
          # This returns an error tuple instead of crashing
          _result = EctoLibSql.Native.ping("invalid-connection")

          # Signal we're done and wait
          send(parent, :done)

          receive do
            :terminate -> :ok
          after
            1000 -> :ok
          end
        end)

      # Wait for completion
      assert_receive :done, 1000

      # Process should still be alive after NIF error
      Process.sleep(10)
      assert Process.alive?(pid)

      # Clean up
      send(pid, :terminate)
    end
  end
end
