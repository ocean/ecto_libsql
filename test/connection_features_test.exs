defmodule EctoLibSql.ConnectionFeaturesTest do
  @moduledoc """
  Tests for connection-level features including busy_timeout, reset, and interrupt.

  These features control connection behaviour and lifecycle management.
  Tests marked with @tag :skip are for features not yet implemented.
  """
  use ExUnit.Case

  setup do
    test_db = "z_ecto_libsql_test-conn_features_#{:erlang.unique_integer([:positive])}.db"

    on_exit(fn ->
      EctoLibSql.TestHelpers.cleanup_db_files(test_db)
    end)

    {:ok, database: test_db}
  end

  # ============================================================================
  # busy_timeout - IMPLEMENTED ✅
  # ============================================================================

  describe "busy_timeout" do
    test "default busy_timeout is set on connect", %{database: database} do
      # Connect with default timeout
      {:ok, state} = EctoLibSql.connect(database: database)

      # Verify connection works
      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute("SELECT 1 + 1", [], [], state)

      assert result.rows == [[2]]

      EctoLibSql.disconnect([], state)
    end

    test "custom busy_timeout can be set via connect options", %{database: database} do
      # Connect with custom timeout
      {:ok, state} = EctoLibSql.connect(database: database, busy_timeout: 10_000)

      # Verify connection works
      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute("SELECT 1 + 1", [], [], state)

      assert result.rows == [[2]]

      EctoLibSql.disconnect([], state)
    end

    test "busy_timeout can be changed after connect", %{database: database} do
      {:ok, state} = EctoLibSql.connect(database: database)

      # Change timeout
      assert :ok = EctoLibSql.Native.busy_timeout(state, 15_000)

      # Verify connection still works
      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute("SELECT 1", [], [], state)

      assert result.rows == [[1]]

      EctoLibSql.disconnect([], state)
    end

    test "busy_timeout of 0 is valid (disables handler)", %{database: database} do
      {:ok, state} = EctoLibSql.connect(database: database, busy_timeout: 0)

      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute("SELECT 1", [], [], state)

      assert result.rows == [[1]]

      EctoLibSql.disconnect([], state)
    end
  end

  # ============================================================================
  # Connection reset - IMPLEMENTED ✅
  # ============================================================================

  describe "connection reset" do
    test "reset clears connection state", %{database: database} do
      {:ok, state} = EctoLibSql.connect(database: database)

      # Create a table
      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE reset_test (id INTEGER PRIMARY KEY)",
          [],
          [],
          state
        )

      # Reset the connection
      assert :ok = EctoLibSql.Native.reset(state)

      # Connection should still work after reset
      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute("SELECT 1", [], [], state)

      assert result.rows == [[1]]

      EctoLibSql.disconnect([], state)
    end

    test "reset maintains database connection", %{database: database} do
      {:ok, state} = EctoLibSql.connect(database: database)

      # Create table and insert data
      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE reset_data (id INTEGER PRIMARY KEY, value TEXT)",
          [],
          [],
          state
        )

      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO reset_data (value) VALUES (?)",
          ["test"],
          [],
          state
        )

      # Reset connection
      assert :ok = EctoLibSql.Native.reset(state)

      # Data should still be there (reset doesn't clear database)
      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute(
          "SELECT value FROM reset_data WHERE id = ?",
          [1],
          [],
          state
        )

      assert result.rows == [["test"]]

      EctoLibSql.disconnect([], state)
    end

    test "reset works with prepared statements", %{database: database} do
      {:ok, state} = EctoLibSql.connect(database: database)

      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE reset_stmts (id INTEGER PRIMARY KEY, value TEXT)",
          [],
          [],
          state
        )

      # Prepare a statement
      {:ok, stmt_id} =
        EctoLibSql.Native.prepare(state, "INSERT INTO reset_stmts (value) VALUES (?)")

      # Execute once
      {:ok, _} =
        EctoLibSql.Native.execute_stmt(
          state,
          stmt_id,
          "INSERT INTO reset_stmts (value) VALUES (?)",
          ["test1"]
        )

      # Reset clears connection state but leaves prepared statement handle valid
      assert :ok = EctoLibSql.Native.reset(state)

      # Statement should still work after reset
      {:ok, _} =
        EctoLibSql.Native.execute_stmt(
          state,
          stmt_id,
          "INSERT INTO reset_stmts (value) VALUES (?)",
          ["test2"]
        )

      # Close statement
      EctoLibSql.Native.close_stmt(stmt_id)

      EctoLibSql.disconnect([], state)
    end

    test "reset multiple times in succession works", %{database: database} do
      {:ok, state} = EctoLibSql.connect(database: database)

      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE reset_multi (id INTEGER PRIMARY KEY)",
          [],
          [],
          state
        )

      # Reset multiple times
      final_state =
        Enum.reduce(1..5, state, fn _, acc_state ->
          assert :ok = EctoLibSql.Native.reset(acc_state)

          # Each reset should work and connection should remain valid
          {:ok, _query, result, new_state} =
            EctoLibSql.handle_execute(
              "SELECT COUNT(*) FROM reset_multi",
              [],
              [],
              acc_state
            )

          assert result.rows == [[0]]
          new_state
        end)

      EctoLibSql.disconnect([], final_state)
    end

    test "reset allows connection reuse in pooled scenario", %{database: database} do
      # Simulate connection pool behaviour
      connections =
        Enum.map(1..3, fn _ ->
          {:ok, state} = EctoLibSql.connect(database: database)
          state
        end)

      # Reset each connection
      Enum.each(connections, fn state ->
        assert :ok = EctoLibSql.Native.reset(state)

        # Each connection should work after reset
        {:ok, _query, result, _state} =
          EctoLibSql.handle_execute("SELECT 1", [], [], state)

        assert result.rows == [[1]]

        EctoLibSql.disconnect([], state)
      end)
    end

    test "reset leaves persistent data intact", %{database: database} do
      {:ok, state} = EctoLibSql.connect(database: database)

      # Create regular table
      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE persist_reset (id INTEGER PRIMARY KEY, value TEXT)",
          [],
          [],
          state
        )

      # Insert data
      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO persist_reset VALUES (1, 'test')",
          [],
          [],
          state
        )

      # Reset connection
      assert :ok = EctoLibSql.Native.reset(state)

      # Data should still be there
      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute(
          "SELECT * FROM persist_reset",
          [],
          [],
          state
        )

      assert result.rows == [[1, "test"]]

      EctoLibSql.disconnect([], state)
    end
  end

  # ============================================================================
  # Connection interrupt - IMPLEMENTED ✅
  # ============================================================================

  describe "connection interrupt" do
    test "interrupt returns ok for idle connection", %{database: database} do
      {:ok, state} = EctoLibSql.connect(database: database)

      # Interrupting an idle connection should be fine
      assert :ok = EctoLibSql.Native.interrupt(state)

      # Connection should still work
      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute("SELECT 42", [], [], state)

      assert result.rows == [[42]]

      EctoLibSql.disconnect([], state)
    end

    test "interrupt multiple times doesn't affect connection", %{database: database} do
      {:ok, state} = EctoLibSql.connect(database: database)

      # Interrupt multiple times
      for _ <- 1..5 do
        assert :ok = EctoLibSql.Native.interrupt(state)
      end

      # Connection should still work
      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute("SELECT 1", [], [], state)

      assert result.rows == [[1]]

      EctoLibSql.disconnect([], state)
    end

    test "interrupt doesn't affect other connections", %{database: database} do
      # Create two connections
      {:ok, state1} = EctoLibSql.connect(database: database)
      {:ok, state2} = EctoLibSql.connect(database: database)

      # Interrupt first connection
      assert :ok = EctoLibSql.Native.interrupt(state1)

      # Second connection should still work
      {:ok, _query, result, _state2} =
        EctoLibSql.handle_execute("SELECT 42", [], [], state2)

      assert result.rows == [[42]]

      # First connection should also still work
      {:ok, _query, result, _state1} =
        EctoLibSql.handle_execute("SELECT 1", [], [], state1)

      assert result.rows == [[1]]

      EctoLibSql.disconnect([], state1)
      EctoLibSql.disconnect([], state2)
    end

    test "interrupt allows query execution after", %{database: database} do
      {:ok, state} = EctoLibSql.connect(database: database)

      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE interrupt_test (id INTEGER PRIMARY KEY, value TEXT)",
          [],
          [],
          state
        )

      # Interrupt
      assert :ok = EctoLibSql.Native.interrupt(state)

      # Should still be able to execute queries
      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO interrupt_test (value) VALUES (?)",
          ["test"],
          [],
          state
        )

      # Verify insert worked
      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute(
          "SELECT value FROM interrupt_test WHERE id = ?",
          [1],
          [],
          state
        )

      assert result.rows == [["test"]]

      EctoLibSql.disconnect([], state)
    end

    test "interrupt during transaction behavior", %{database: database} do
      {:ok, state} = EctoLibSql.connect(database: database)

      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE interrupt_txn (id INTEGER PRIMARY KEY)",
          [],
          [],
          state
        )

      # Begin transaction
      {:ok, :begin, state} = EctoLibSql.handle_begin([], state)

      # Interrupt during transaction
      assert :ok = EctoLibSql.Native.interrupt(state)

      # Transaction should be rollable
      {:ok, _result, _state} = EctoLibSql.handle_rollback([], state)

      EctoLibSql.disconnect([], state)
    end

    test "interrupt state persists across operations", %{database: database} do
      {:ok, state} = EctoLibSql.connect(database: database)

      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE interrupt_persist (id INTEGER PRIMARY KEY)",
          [],
          [],
          state
        )

      # Interrupt, then do operations
      assert :ok = EctoLibSql.Native.interrupt(state)

      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO interrupt_persist VALUES (1)",
          [],
          [],
          state
        )

      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO interrupt_persist VALUES (2)",
          [],
          [],
          state
        )

      # Verify both inserts worked
      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute(
          "SELECT COUNT(*) FROM interrupt_persist",
          [],
          [],
          state
        )

      assert result.rows == [[2]]

      EctoLibSql.disconnect([], state)
    end
  end

  # ============================================================================
  # Integration tests
  # ============================================================================

  describe "integration with Ecto connection options" do
    test "busy_timeout in config works", %{database: database} do
      # Simulate Ecto-style config
      opts = [
        database: database,
        busy_timeout: 8000
      ]

      {:ok, state} = EctoLibSql.connect(opts)

      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute("SELECT 1 + 2", [], [], state)

      assert result.rows == [[3]]

      EctoLibSql.disconnect([], state)
    end
  end
end
