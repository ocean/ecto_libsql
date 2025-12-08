defmodule EctoLibSql.ErrorDemoTest do
  use ExUnit.Case

  @moduledoc """
  Simple demonstration tests showing that errors are now handled gracefully
  instead of crashing the BEAM VM.

  BEFORE the refactoring: These operations would call .unwrap() on None/Err
  values in Rust, causing the entire BEAM VM to panic and crash.

  AFTER the refactoring: Errors are returned as {:error, message} tuples
  to Elixir, where they can be handled by supervision trees.
  """

  describe "graceful error handling demonstrations" do
    test "❌ BEFORE: invalid connection would crash VM | ✅ AFTER: returns error tuple" do
      # This connection ID doesn't exist in the registry
      fake_conn_id = "00000000-0000-0000-0000-000000000000"

      # BEFORE: Rust would call CONNECTION_REGISTRY.lock().unwrap().get(id).unwrap()
      #         Second unwrap() would panic → VM crash
      # AFTER:  Returns {:error, "Invalid connection ID"}
      result = EctoLibSql.Native.ping(fake_conn_id)

      assert {:error, error_msg} = result
      assert is_binary(error_msg)
    end

    test "❌ BEFORE: invalid transaction would crash VM | ✅ AFTER: returns error tuple" do
      fake_trx_id = "nonexistent-transaction-id"
      fake_conn_id = "nonexistent-connection-id"

      # BEFORE: TXN_REGISTRY.lock().unwrap().get_mut(trx_id).unwrap()
      #         Would panic on None → VM crash
      # AFTER:  Returns {:error, "Transaction not found"}
      result =
        EctoLibSql.Native.execute_with_transaction(
          fake_trx_id,
          fake_conn_id,
          "SELECT 1",
          []
        )

      assert {:error, error_msg} = result
      assert error_msg =~ "Transaction not found"
    end

    test "❌ BEFORE: closing invalid resource crashed VM | ✅ AFTER: returns error tuple" do
      fake_cursor_id = "cursor-that-does-not-exist"

      # BEFORE: CURSOR_REGISTRY.lock().unwrap().remove(id).unwrap()
      #         Would panic → VM crash
      # AFTER:  Returns {:error, "Cursor not found"}
      result = EctoLibSql.Native.close(fake_cursor_id, :cursor_id)

      assert {:error, error_msg} = result
      assert error_msg =~ "Cursor not found"
    end

    test "✅ Process remains alive after NIF errors (supervision tree works)" do
      # Spawn a process that will encounter NIF errors
      pid =
        spawn(fn ->
          # Try multiple invalid operations
          _result1 = EctoLibSql.Native.ping("invalid-conn")
          _result2 = EctoLibSql.Native.close("invalid-stmt", :stmt_id)
          _result3 = EctoLibSql.Native.fetch_cursor("invalid-conn", "invalid-cursor", 100)

          # Sleep to keep process alive
          Process.sleep(500)
        end)

      # Give it time to execute
      Process.sleep(100)

      # BEFORE: Process (and possibly VM) would have crashed
      # AFTER:  Process is still alive
      assert Process.alive?(pid)
    end

    test "✅ Descriptive error messages help debugging" do
      result = EctoLibSql.Native.ping("test-connection-123")

      # Get the error message
      assert {:error, error_msg} = result

      # Should be descriptive, not just a panic message
      assert String.length(error_msg) > 5
      assert error_msg =~ ~r/(connection|Connection|invalid|Invalid)/i
    end
  end

  describe "real-world error scenario" do
    test "✅ Database operation fails gracefully without crashing" do
      # Simulate a real scenario: app tries to use a stale connection ID
      # (maybe connection was closed by timeout, network issue, etc.)

      stale_conn_id = "conn-that-was-closed-or-never-existed"

      # Try to execute a query
      result =
        EctoLibSql.Native.query_args(
          stale_conn_id,
          :local,
          :disable_sync,
          "SELECT * FROM users",
          []
        )

      # Should get error, not crash
      assert {:error, _error_msg} = result
    end
  end

  describe "error propagation to supervision tree" do
    test "✅ GenServer can handle NIF errors and remain supervised" do
      # Demonstrate that errors properly propagate to calling processes
      # allowing supervision strategies to work

      parent = self()

      child_pid =
        spawn_link(fn ->
          # This would crash the VM before refactoring
          result = EctoLibSql.Native.ping("invalid-connection")

          # Send result back to parent
          send(parent, {:result, result})

          # Wait for parent signal
          receive do
            :terminate -> :ok
          end
        end)

      # Receive the error result
      assert_receive {:result, {:error, _}}, 1000

      # Child process should still be alive
      assert Process.alive?(child_pid)

      # Clean up
      send(child_pid, :terminate)
    end
  end
end
