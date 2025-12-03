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
  # query_row() - NOT IMPLEMENTED ❌
  # ============================================================================

  describe "query_row() - NOT IMPLEMENTED" do
    @describetag :skip

    test "returns single row from query", %{state: state} do
      # Insert test data
      {:ok, _, _, state} =
        EctoLibSql.handle_execute("INSERT INTO users VALUES (1, 'Alice', 30)", [], [], state)

      # Prepare statement
      {:ok, stmt_id} =
        EctoLibSql.Native.prepare(state, "SELECT name, age FROM users WHERE id = ?")

      # Query single row
      assert {:ok, row} = EctoLibSql.Native.query_row(state, stmt_id, [1])

      assert ["Alice", 30] = row

      # Cleanup
      EctoLibSql.Native.close_stmt(stmt_id)
    end

    test "query_row errors if no rows", %{state: state} do
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "SELECT * FROM users WHERE id = ?")

      # Should error if no rows
      assert {:error, :no_rows} = EctoLibSql.Native.query_row(state, stmt_id, [999])

      EctoLibSql.Native.close_stmt(stmt_id)
    end

    test "query_row errors if multiple rows", %{state: state} do
      # Insert multiple rows
      {:ok, _, _, state} =
        EctoLibSql.handle_execute("INSERT INTO users VALUES (1, 'Alice', 30)", [], [], state)

      {:ok, _, _, state} =
        EctoLibSql.handle_execute("INSERT INTO users VALUES (2, 'Bob', 25)", [], [], state)

      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "SELECT * FROM users")

      # Should error if multiple rows
      assert {:error, :multiple_rows} = EctoLibSql.Native.query_row(state, stmt_id, [])

      EctoLibSql.Native.close_stmt(stmt_id)
    end

    test "query_row is more efficient than query + take first", %{state: state} do
      # Insert 1000 rows
      for i <- 1..1000 do
        {:ok, _, _, state} =
          EctoLibSql.handle_execute(
            "INSERT INTO users VALUES (?, ?, ?)",
            [i, "User#{i}", 20 + rem(i, 50)],
            [],
            state
          )
      end

      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "SELECT * FROM users")

      # query_row should stop after first row (fast)
      {time_query_row, {:error, :multiple_rows}} =
        :timer.tc(fn -> EctoLibSql.Native.query_row(state, stmt_id, []) end)

      # Should be fast even though table has 1000 rows
      # (It should error quickly after seeing 2nd row)
      assert time_query_row / 1000 < 10

      # Compare to fetching all rows
      {:ok, stmt_id2} = EctoLibSql.Native.prepare(state, "SELECT * FROM users")

      {time_query_all, {:ok, _result}} =
        :timer.tc(fn -> EctoLibSql.Native.query_stmt(state, stmt_id2, []) end)

      # query_row should be much faster (doesn't fetch all 1000 rows)
      assert time_query_row < time_query_all / 2

      EctoLibSql.Native.close_stmt(stmt_id)
      EctoLibSql.Native.close_stmt(stmt_id2)
    end
  end

  # ============================================================================
  # Statement.reset() - NOT IMPLEMENTED ❌
  # ============================================================================

  describe "Statement.reset() - NOT IMPLEMENTED" do
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

  describe "Statement parameter introspection - NOT IMPLEMENTED" do
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
