defmodule EctoLibSql.SavepointTest do
  @moduledoc """
  Tests for savepoint functionality in transactions.
  Tests the Phase 1 features from the roadmap.
  """

  use ExUnit.Case, async: true

  alias EctoLibSql.Native
  alias EctoLibSql.State
  alias EctoLibSql.Query

  # Helper function to execute raw SQL
  defp exec_sql(state, sql, args \\ []) do
    query = %Query{statement: sql}
    Native.query(state, query, args)
  end

  # Helper function to execute SQL within a transaction
  defp exec_trx_sql(state, sql, args) do
    query = %Query{statement: sql}
    Native.execute_with_trx(state, query, args)
  end

  setup do
    # Create unique database file for this test
    db_file = "z_ecto_libsql_test-savepoint_#{:erlang.unique_integer([:positive])}.db"

    conn_id = Native.connect([database: db_file], :local)
    state = %State{conn_id: conn_id, mode: :local, sync: :disable_sync}

    # Create test table
    {:ok, _query, _result, state} =
      exec_sql(state, "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")

    on_exit(fn ->
      Native.close(state.conn_id, :conn_id)
      File.rm(db_file)
      File.rm(db_file <> "-shm")
      File.rm(db_file <> "-wal")
    end)

    {:ok, state: state}
  end

  describe "savepoint creation" do
    test "create savepoint in transaction", %{state: state} do
      {:ok, trx_state} = Native.begin(state)

      assert :ok = Native.create_savepoint(trx_state, "sp1")

      # Commit transaction
      {:ok, _committed_state} = Native.commit(trx_state)
    end

    test "create nested savepoints (3 levels deep)", %{state: state} do
      {:ok, trx_state} = Native.begin(state)

      assert :ok = Native.create_savepoint(trx_state, "sp1")
      assert :ok = Native.create_savepoint(trx_state, "sp2")
      assert :ok = Native.create_savepoint(trx_state, "sp3")

      # Cleanup
      {:ok, _committed_state} = Native.commit(trx_state)
    end

    test "create savepoint with custom name", %{state: state} do
      {:ok, trx_state} = Native.begin(state)

      assert :ok = Native.create_savepoint(trx_state, "my_custom_savepoint")

      {:ok, _committed_state} = Native.commit(trx_state)
    end

    test "create duplicate savepoint name may return error or succeed", %{state: state} do
      {:ok, trx_state} = Native.begin(state)

      assert :ok = Native.create_savepoint(trx_state, "sp1")

      # Creating duplicate savepoint may return error or succeed depending on backend
      result = Native.create_savepoint(trx_state, "sp1")

      case result do
        {:error, _reason} ->
          :ok

        :ok ->
          :ok
          # SQLite might allow duplicate savepoints, just replacing the old one
      end

      {:ok, _rolled_back_state} = Native.rollback(trx_state)
    end

    test "create savepoint outside transaction returns error", %{state: state} do
      # No transaction started
      result = Native.create_savepoint(state, "sp1")

      assert {:error, reason} = result
      assert reason =~ "No active transaction"
    end
  end

  describe "savepoint rollback" do
    test "rollback to savepoint preserves outer transaction", %{state: state} do
      {:ok, trx_state} = Native.begin(state)

      # Insert first user
      {:ok, _query, _result, trx_state} =
        exec_trx_sql(trx_state, "INSERT INTO users (id, name) VALUES (?, ?)", [
          1,
          "Alice"
        ])

      # Create savepoint
      :ok = Native.create_savepoint(trx_state, "sp1")

      # Insert second user
      {:ok, _query, _result, trx_state} =
        exec_trx_sql(trx_state, "INSERT INTO users (id, name) VALUES (?, ?)", [
          2,
          "Bob"
        ])

      # Rollback to savepoint (should remove Bob, keep Alice)
      :ok = Native.rollback_to_savepoint_by_name(trx_state, "sp1")

      # Commit transaction
      {:ok, _committed_state} = Native.commit(trx_state)

      # Verify only Alice exists
      {:ok, _query, result, _state} = exec_sql(state, "SELECT * FROM users")
      assert length(result.rows) == 1
      assert hd(result.rows) == [1, "Alice"]
    end

    test "rollback to savepoint undoes changes after savepoint", %{state: state} do
      {:ok, trx_state} = Native.begin(state)

      # Create savepoint before any changes
      :ok = Native.create_savepoint(trx_state, "sp1")

      # Insert user
      {:ok, _query, _result, trx_state} =
        exec_trx_sql(trx_state, "INSERT INTO users (id, name) VALUES (?, ?)", [
          1,
          "Alice"
        ])

      # Rollback to savepoint (should remove Alice)
      :ok = Native.rollback_to_savepoint_by_name(trx_state, "sp1")

      # Commit transaction
      {:ok, _committed_state} = Native.commit(trx_state)

      # Verify no users exist
      {:ok, _query, result, _state} = exec_sql(state, "SELECT * FROM users")
      assert result.rows == []
    end

    test "rollback to savepoint allows continuing transaction", %{state: state} do
      {:ok, trx_state} = Native.begin(state)

      # Insert and create savepoint
      {:ok, _query, _result, trx_state} =
        exec_trx_sql(trx_state, "INSERT INTO users (id, name) VALUES (?, ?)", [
          1,
          "Alice"
        ])

      :ok = Native.create_savepoint(trx_state, "sp1")

      {:ok, _query, _result, trx_state} =
        exec_trx_sql(trx_state, "INSERT INTO users (id, name) VALUES (?, ?)", [
          2,
          "Bob"
        ])

      # Rollback
      :ok = Native.rollback_to_savepoint_by_name(trx_state, "sp1")

      # Continue with more inserts
      {:ok, _query, _result, trx_state} =
        exec_trx_sql(trx_state, "INSERT INTO users (id, name) VALUES (?, ?)", [
          3,
          "Charlie"
        ])

      # Commit
      {:ok, _committed_state} = Native.commit(trx_state)

      # Verify Alice and Charlie exist, not Bob
      {:ok, _query, result, _state} = exec_sql(state, "SELECT * FROM users ORDER BY id")
      assert length(result.rows) == 2
      assert Enum.at(result.rows, 0) == [1, "Alice"]
      assert Enum.at(result.rows, 1) == [3, "Charlie"]
    end

    test "rollback to non-existent savepoint returns error", %{state: state} do
      {:ok, trx_state} = Native.begin(state)

      result = Native.rollback_to_savepoint_by_name(trx_state, "nonexistent")

      assert {:error, _reason} = result

      {:ok, _rolled_back_state} = Native.rollback(trx_state)
    end

    test "rollback middle savepoint preserves outer and inner", %{state: state} do
      {:ok, trx_state} = Native.begin(state)

      # Insert user 1
      {:ok, _query, _result, trx_state} =
        exec_trx_sql(trx_state, "INSERT INTO users (id, name) VALUES (?, ?)", [
          1,
          "Alice"
        ])

      :ok = Native.create_savepoint(trx_state, "sp1")

      # Insert user 2
      {:ok, _query, _result, trx_state} =
        exec_trx_sql(trx_state, "INSERT INTO users (id, name) VALUES (?, ?)", [
          2,
          "Bob"
        ])

      :ok = Native.create_savepoint(trx_state, "sp2")

      # Insert user 3
      {:ok, _query, _result, trx_state} =
        exec_trx_sql(trx_state, "INSERT INTO users (id, name) VALUES (?, ?)", [
          3,
          "Charlie"
        ])

      # Rollback to sp1 (removes Bob and Charlie, keeps Alice)
      :ok = Native.rollback_to_savepoint_by_name(trx_state, "sp1")

      {:ok, _committed_state} = Native.commit(trx_state)

      # Verify only Alice exists
      {:ok, _query, result, _state} = exec_sql(state, "SELECT * FROM users")
      assert length(result.rows) == 1
      assert hd(result.rows) == [1, "Alice"]
    end
  end

  describe "savepoint release" do
    test "release savepoint commits changes", %{state: state} do
      {:ok, trx_state} = Native.begin(state)

      :ok = Native.create_savepoint(trx_state, "sp1")

      {:ok, _query, _result, trx_state} =
        exec_trx_sql(trx_state, "INSERT INTO users (id, name) VALUES (?, ?)", [
          1,
          "Alice"
        ])

      # Release savepoint
      :ok = Native.release_savepoint_by_name(trx_state, "sp1")

      # Commit transaction
      {:ok, _committed_state} = Native.commit(trx_state)

      # Verify Alice exists
      {:ok, _query, result, _state} = exec_sql(state, "SELECT * FROM users")
      assert length(result.rows) == 1
      assert hd(result.rows) == [1, "Alice"]
    end

    test "release savepoint allows transaction commit", %{state: state} do
      {:ok, trx_state} = Native.begin(state)

      :ok = Native.create_savepoint(trx_state, "sp1")

      {:ok, _query, _result, trx_state} =
        exec_trx_sql(trx_state, "INSERT INTO users (id, name) VALUES (?, ?)", [
          1,
          "Alice"
        ])

      :ok = Native.release_savepoint_by_name(trx_state, "sp1")

      # Should be able to commit after releasing savepoint
      {:ok, _committed_state} = Native.commit(trx_state)
    end

    test "release non-existent savepoint returns error", %{state: state} do
      {:ok, trx_state} = Native.begin(state)

      result = Native.release_savepoint_by_name(trx_state, "nonexistent")

      assert {:error, _reason} = result

      {:ok, _rolled_back_state} = Native.rollback(trx_state)
    end

    test "release all savepoints then commit works", %{state: state} do
      {:ok, trx_state} = Native.begin(state)

      :ok = Native.create_savepoint(trx_state, "sp1")
      :ok = Native.create_savepoint(trx_state, "sp2")

      {:ok, _query, _result, trx_state} =
        exec_trx_sql(trx_state, "INSERT INTO users (id, name) VALUES (?, ?)", [
          1,
          "Alice"
        ])

      # Release both savepoints
      :ok = Native.release_savepoint_by_name(trx_state, "sp2")
      :ok = Native.release_savepoint_by_name(trx_state, "sp1")

      # Commit
      {:ok, _committed_state} = Native.commit(trx_state)

      # Verify data committed
      {:ok, _query, result, _state} = exec_sql(state, "SELECT * FROM users")
      assert length(result.rows) == 1
    end
  end

  describe "error scenarios" do
    test "error in savepoint can be rolled back", %{state: state} do
      {:ok, trx_state} = Native.begin(state)

      {:ok, _query, _result, trx_state} =
        exec_trx_sql(trx_state, "INSERT INTO users (id, name) VALUES (?, ?)", [
          1,
          "Alice"
        ])

      :ok = Native.create_savepoint(trx_state, "sp1")

      # Try to insert duplicate primary key (will fail)
      result =
        exec_trx_sql(trx_state, "INSERT INTO users (id, name) VALUES (?, ?)", [
          1,
          "Bob"
        ])

      assert {:error, _reason, _state} = result

      # Rollback savepoint to recover
      :ok = Native.rollback_to_savepoint_by_name(trx_state, "sp1")

      # Should be able to continue
      {:ok, _query, _result, trx_state} =
        exec_trx_sql(trx_state, "INSERT INTO users (id, name) VALUES (?, ?)", [
          2,
          "Charlie"
        ])

      {:ok, _committed_state} = Native.commit(trx_state)

      # Verify Alice and Charlie exist
      {:ok, _query, result, _state} = exec_sql(state, "SELECT * FROM users ORDER BY id")
      assert length(result.rows) == 2
      assert Enum.at(result.rows, 0) == [1, "Alice"]
      assert Enum.at(result.rows, 1) == [2, "Charlie"]
    end

    test "multiple savepoint rollbacks work correctly", %{state: state} do
      {:ok, trx_state} = Native.begin(state)

      :ok = Native.create_savepoint(trx_state, "sp1")

      {:ok, _query, _result, trx_state} =
        exec_trx_sql(trx_state, "INSERT INTO users (id, name) VALUES (?, ?)", [
          1,
          "Alice"
        ])

      # Rollback and retry
      :ok = Native.rollback_to_savepoint_by_name(trx_state, "sp1")

      {:ok, _query, _result, trx_state} =
        exec_trx_sql(trx_state, "INSERT INTO users (id, name) VALUES (?, ?)", [
          2,
          "Bob"
        ])

      # Rollback again
      :ok = Native.rollback_to_savepoint_by_name(trx_state, "sp1")

      {:ok, _query, _result, trx_state} =
        exec_trx_sql(trx_state, "INSERT INTO users (id, name) VALUES (?, ?)", [
          3,
          "Charlie"
        ])

      {:ok, _committed_state} = Native.commit(trx_state)

      # Only Charlie should exist
      {:ok, _query, result, _state} = exec_sql(state, "SELECT * FROM users")
      assert length(result.rows) == 1
      assert hd(result.rows) == [3, "Charlie"]
    end
  end

  describe "complex savepoint scenarios" do
    test "nested savepoints with partial rollback", %{state: state} do
      {:ok, trx_state} = Native.begin(state)

      # Level 0: Insert Alice
      {:ok, _query, _result, trx_state} =
        exec_trx_sql(trx_state, "INSERT INTO users (id, name) VALUES (?, ?)", [
          1,
          "Alice"
        ])

      # Level 1: Savepoint sp1
      :ok = Native.create_savepoint(trx_state, "sp1")

      {:ok, _query, _result, trx_state} =
        exec_trx_sql(trx_state, "INSERT INTO users (id, name) VALUES (?, ?)", [
          2,
          "Bob"
        ])

      # Level 2: Savepoint sp2
      :ok = Native.create_savepoint(trx_state, "sp2")

      {:ok, _query, _result, trx_state} =
        exec_trx_sql(trx_state, "INSERT INTO users (id, name) VALUES (?, ?)", [
          3,
          "Charlie"
        ])

      # Rollback to sp2 (removes Charlie)
      :ok = Native.rollback_to_savepoint_by_name(trx_state, "sp2")

      # Continue at level 2
      {:ok, _query, _result, trx_state} =
        exec_trx_sql(trx_state, "INSERT INTO users (id, name) VALUES (?, ?)", [
          4,
          "David"
        ])

      # Release sp2
      :ok = Native.release_savepoint_by_name(trx_state, "sp2")

      # Rollback to sp1 (removes Bob and David, keeps Alice)
      :ok = Native.rollback_to_savepoint_by_name(trx_state, "sp1")

      {:ok, _committed_state} = Native.commit(trx_state)

      # Only Alice should exist
      {:ok, _query, result, _state} = exec_sql(state, "SELECT * FROM users")
      assert length(result.rows) == 1
      assert hd(result.rows) == [1, "Alice"]
    end

    test "savepoint for optional audit logging pattern", %{state: state} do
      {:ok, trx_state} = Native.begin(state)

      # Main operation
      {:ok, _query, _result, trx_state} =
        exec_trx_sql(trx_state, "INSERT INTO users (id, name) VALUES (?, ?)", [
          1,
          "Alice"
        ])

      # Try optional audit log (might fail, shouldn't affect main operation)
      :ok = Native.create_savepoint(trx_state, "audit")

      # Simulate audit log failure (table doesn't exist)
      audit_result =
        exec_trx_sql(
          trx_state,
          "INSERT INTO audit_log (user_id, action) VALUES (?, ?)",
          [1, "created"]
        )

      case audit_result do
        {:ok, _query, _result, trx_state} ->
          # Audit succeeded, release savepoint
          :ok = Native.release_savepoint_by_name(trx_state, "audit")
          {:ok, _committed_state} = Native.commit(trx_state)

        {:error, _reason, trx_state} ->
          # Audit failed, rollback savepoint but keep main operation
          :ok = Native.rollback_to_savepoint_by_name(trx_state, "audit")
          {:ok, _committed_state} = Native.commit(trx_state)
      end

      # User should still be inserted regardless of audit log
      {:ok, _query, result, _state} = exec_sql(state, "SELECT * FROM users")
      assert length(result.rows) == 1
      assert hd(result.rows) == [1, "Alice"]
    end
  end
end
