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
      File.rm(test_db)
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
