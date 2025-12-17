defmodule EctoLibSql.StatementFeaturesTest do
  @moduledoc """
  Tests for prepared statement features.

  Includes:
  - Basic prepare/execute
  - Statement introspection: columns(), parameter_count()
  - Statement reset() for reuse
  """
  use ExUnit.Case

  setup do
    test_db = "z_ecto_libsql_test-stmt_#{:erlang.unique_integer([:positive])}.db"

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

  describe "Statement.columns()" do
    test "get column metadata from prepared statement", %{state: state} do
      # Prepare statement
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "SELECT * FROM users WHERE id = ?")

      # Get column count
      {:ok, count} = EctoLibSql.Native.stmt_column_count(state, stmt_id)
      assert count == 3

      # Get column names using helper function
      names = get_column_names(state, stmt_id, count)
      assert names == ["id", "name", "age"]

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

      # Get column count
      {:ok, count} = EctoLibSql.Native.stmt_column_count(state, stmt_id)
      assert count == 3

      # Get column names using helper function
      names = get_column_names(state, stmt_id, count)
      assert names == ["user_id", "name", "post_count"]

      # Cleanup
      EctoLibSql.Native.close_stmt(stmt_id)
    end

    test "stmt_column_name handles out-of-bounds and valid indices", %{state: state} do
      # Prepare statement
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "SELECT * FROM users WHERE id = ?")

      # Get column count
      {:ok, count} = EctoLibSql.Native.stmt_column_count(state, stmt_id)
      assert count == 3

      # Valid indices (0 to count-1) should succeed
      {:ok, name_0} = EctoLibSql.Native.stmt_column_name(state, stmt_id, 0)
      assert name_0 == "id"

      {:ok, name_2} = EctoLibSql.Native.stmt_column_name(state, stmt_id, 2)
      assert name_2 == "age"

      # Out-of-bounds indices should return error
      assert {:error, _} = EctoLibSql.Native.stmt_column_name(state, stmt_id, count)
      assert {:error, _} = EctoLibSql.Native.stmt_column_name(state, stmt_id, 100)

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

  describe "Statement reset and caching ✅" do
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

      # Execute multiple times - statement caching handles reset automatically
      for i <- 1..5 do
        {:ok, _rows} =
          EctoLibSql.Native.execute_stmt(
            state,
            stmt_id,
            "INSERT INTO logs (message) VALUES (?)",
            ["Log #{i}"]
          )
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

      # Execute with parameters - automatic reset between calls
      {:ok, _} =
        EctoLibSql.Native.execute_stmt(state, stmt_id, "INSERT INTO users VALUES (?, ?, ?)", [
          1,
          "Alice",
          30
        ])

      # Execute with different parameters - no manual reset needed
      {:ok, _} =
        EctoLibSql.Native.execute_stmt(state, stmt_id, "INSERT INTO users VALUES (?, ?, ?)", [
          2,
          "Bob",
          25
        ])

      # Verify both inserts
      {:ok, _, result, _} =
        EctoLibSql.handle_execute("SELECT name FROM users ORDER BY id", [], [], state)

      assert [["Alice"], ["Bob"]] = result.rows

      EctoLibSql.Native.close_stmt(stmt_id)
    end

    @tag :flaky
    test "statement caching improves performance vs re-prepare", %{state: state} do
      sql = "INSERT INTO users VALUES (?, ?, ?)"

      # Time cached prepared statement (prepare once, execute many times)
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, sql)

      {time_with_cache, _} =
        :timer.tc(fn ->
          for i <- 1..100 do
            EctoLibSql.Native.execute_stmt(state, stmt_id, sql, [i, "User#{i}", 20 + i])
          end
        end)

      EctoLibSql.Native.close_stmt(stmt_id)

      # Verify all inserts succeeded
      {:ok, _, result, _} =
        EctoLibSql.handle_execute("SELECT COUNT(*) FROM users", [], [], state)

      assert [[100]] = result.rows

      # Clear for next benchmark
      {:ok, _, _, state} = EctoLibSql.handle_execute("DELETE FROM users", [], [], state)

      # Time re-prepare approach (prepare and close each time)
      {time_with_prepare, _} =
        :timer.tc(fn ->
          for i <- 1..100 do
            {:ok, stmt} = EctoLibSql.Native.prepare(state, sql)
            EctoLibSql.Native.execute_stmt(state, stmt, sql, [i + 100, "User#{i}", 20 + i])
            EctoLibSql.Native.close_stmt(stmt)
          end
        end)

      # Caching should provide measurable benefit (at least not worse on average)
      # Note: allowing significant variance for CI/test environments
      # On GitHub Actions and other CI platforms, performance can vary wildly
      ratio = time_with_cache / time_with_prepare

      # Very lenient threshold for CI environments - just verify caching doesn't
      # make things dramatically worse (10x threshold instead of 2x)
      assert ratio <= 10,
             "Cached statements should not be dramatically slower than re-prepare (got #{ratio}x)"
    end
  end

  # ============================================================================
  # Statement parameter introspection - NOT IMPLEMENTED ❌
  # ============================================================================

  describe "Statement parameter introspection ✅" do
    test "parameter_count returns number of parameters", %{state: state} do
      {:ok, stmt_id} =
        EctoLibSql.Native.prepare(state, "SELECT * FROM users WHERE name = ? AND age > ?")

      assert {:ok, 2} = EctoLibSql.Native.stmt_parameter_count(state, stmt_id)

      EctoLibSql.Native.close_stmt(stmt_id)
    end
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  # Retrieve all column names from a prepared statement.
  # This helper reduces duplication when working with multiple column names
  # from the same statement. It iterates from 0 to count-1 and retrieves
  # each column name using stmt_column_name/3.
  defp get_column_names(state, stmt_id, count) do
    for i <- 0..(count - 1) do
      {:ok, name} = EctoLibSql.Native.stmt_column_name(state, stmt_id, i)
      name
    end
  end
end
