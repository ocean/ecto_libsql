defmodule EctoLibSql.StatementFeaturesTest do
  @moduledoc """
  Tests for prepared statement features.

  Includes:
  - Basic prepare/execute (implemented)
  - Statement introspection: columns(), parameter_count() (not implemented)
  - Statement reset() for reuse (not implemented)
  - query_row() for single-row queries (not implemented)
  """
  use ExUnit.Case

  setup do
    test_db = "test_stmt_#{:erlang.unique_integer([:positive])}.db"

    {:ok, state} = EctoLibSql.connect(database: test_db)

    # Create a test table
    {:ok, _, _, state} =
      EctoLibSql.handle_execute(
        "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)",
        [],
        [],
        state
      )

    on_exit(fn ->
      EctoLibSql.disconnect([], state)
      File.rm(test_db)
    end)

    {:ok, state: state}
  end

  # ============================================================================
  # Statement.columns() - NOT IMPLEMENTED ❌
  # ============================================================================

  describe "Statement.columns() - NOT IMPLEMENTED" do
    @describetag :skip

    test "get column metadata from prepared statement", %{state: state} do
      # Prepare statement
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "SELECT * FROM users WHERE id = ?")

      # Get columns
      assert {:ok, columns} = EctoLibSql.Native.get_statement_columns(stmt_id)

      assert length(columns) == 3

      assert %{name: "id", decl_type: "INTEGER"} = Enum.at(columns, 0)
      assert %{name: "name", decl_type: "TEXT"} = Enum.at(columns, 1)
      assert %{name: "age", decl_type: "INTEGER"} = Enum.at(columns, 2)

      # Cleanup
      EctoLibSql.Native.close_stmt(stmt_id)
    end

    test "columns work with complex queries", %{state: state} do
      # Create posts table
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER, title TEXT)",
          [],
          [],
          state
        )

      # Prepare complex query
      {:ok, stmt_id} =
        EctoLibSql.Native.prepare(
          state,
          """
          SELECT
            u.id as user_id,
            u.name,
            COUNT(p.id) as post_count
          FROM users u
          LEFT JOIN posts p ON u.id = p.user_id
          GROUP BY u.id
          """
        )

      # Get columns
      assert {:ok, columns} = EctoLibSql.Native.get_statement_columns(stmt_id)

      assert length(columns) == 3

      # Column names from query
      assert %{name: "user_id"} = Enum.at(columns, 0)
      assert %{name: "name"} = Enum.at(columns, 1)
      assert %{name: "post_count"} = Enum.at(columns, 2)

      # Cleanup
      EctoLibSql.Native.close_stmt(stmt_id)
    end
  end

  # ============================================================================
  # NOTE: query_row() is NOT in the libsql Rust crate API
  # It's an Elixir convenience function that doesn't exist upstream
  # Users should use query_stmt() and take the first row if needed
  # Removed to keep tests aligned with actual libsql features
  # ============================================================================

  # ============================================================================
  # Statement.reset() - NOT IMPLEMENTED ❌
  # ============================================================================

  describe "Statement.reset() - NOW IMPLEMENTED ✅" do
    @describetag :skip

    test "reset statement for reuse without re-prepare", %{state: state} do
      # Create logs table
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE logs (id INTEGER PRIMARY KEY AUTOINCREMENT, message TEXT)",
          [],
          [],
          state
        )

      # Prepare statement once
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "INSERT INTO logs (message) VALUES (?)")

      # Execute multiple times with reset
      for i <- 1..5 do
        {:ok, _rows} =
          EctoLibSql.Native.execute_stmt(state, stmt_id, "INSERT ...", ["Log #{i}"])

        # Reset for reuse
        {:ok, _} = EctoLibSql.Native.reset_stmt(stmt_id)
      end

      # Verify all inserts succeeded
      {:ok, _, result, _} =
        EctoLibSql.handle_execute("SELECT COUNT(*) FROM logs", [], [], state)

      assert [[5]] = result.rows

      # Cleanup
      EctoLibSql.Native.close_stmt(stmt_id)
    end

    test "reset clears parameter bindings", %{state: state} do
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "INSERT INTO users VALUES (?, ?, ?)")

      # Execute with parameters
      {:ok, _} = EctoLibSql.Native.execute_stmt(state, stmt_id, "INSERT ...", [1, "Alice", 30])

      # Reset clears bindings
      {:ok, _} = EctoLibSql.Native.reset_stmt(stmt_id)

      # Execute with different parameters
      {:ok, _} = EctoLibSql.Native.execute_stmt(state, stmt_id, "INSERT ...", [2, "Bob", 25])

      # Verify both inserts
      {:ok, _, result, _} =
        EctoLibSql.handle_execute("SELECT name FROM users ORDER BY id", [], [], state)

      assert [["Alice"], ["Bob"]] = result.rows

      EctoLibSql.Native.close_stmt(stmt_id)
    end

    test "reset is faster than re-prepare", %{state: state} do
      sql = "INSERT INTO users VALUES (?, ?, ?)"

      # Benchmark with reset
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, sql)

      {time_with_reset, _} =
        :timer.tc(fn ->
          for i <- 1..100 do
            EctoLibSql.Native.execute_stmt(state, stmt_id, sql, [i, "User#{i}", 20 + i])
            EctoLibSql.Native.reset_stmt(stmt_id)
          end
        end)

      EctoLibSql.Native.close_stmt(stmt_id)

      # Clear table
      {:ok, _, _, state} = EctoLibSql.handle_execute("DELETE FROM users", [], [], state)

      # Benchmark with re-prepare
      {time_with_prepare, _} =
        :timer.tc(fn ->
          for i <- 1..100 do
            {:ok, stmt} = EctoLibSql.Native.prepare(state, sql)
            EctoLibSql.Native.execute_stmt(state, stmt, sql, [i + 100, "User#{i}", 20 + i])
            EctoLibSql.Native.close_stmt(stmt)
          end
        end)

      # Reset should be significantly faster
      assert time_with_reset < time_with_prepare / 2
    end
  end

  # ============================================================================
  # Statement parameter introspection - NOT IMPLEMENTED ❌
  # ============================================================================

  describe "Statement parameter introspection - NOW IMPLEMENTED ✅" do
    @describetag :skip

    test "parameter_count returns number of parameters", %{state: state} do
      {:ok, stmt_id} =
        EctoLibSql.Native.prepare(state, "SELECT * FROM users WHERE name = ? AND age > ?")

      assert {:ok, 2} = EctoLibSql.Native.statement_parameter_count(stmt_id)

      EctoLibSql.Native.close_stmt(stmt_id)
    end

    test "parameter_name returns parameter names for named params", %{state: state} do
      {:ok, stmt_id} =
        EctoLibSql.Native.prepare(state, "SELECT * FROM users WHERE name = :name AND age > :age")

      assert {:ok, ":name"} = EctoLibSql.Native.statement_parameter_name(stmt_id, 1)
      assert {:ok, ":age"} = EctoLibSql.Native.statement_parameter_name(stmt_id, 2)

      EctoLibSql.Native.close_stmt(stmt_id)
    end
  end
end
