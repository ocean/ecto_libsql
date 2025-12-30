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
    {:ok, _query, _result, state} =
      EctoLibSql.handle_execute(
        "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)",
        [],
        [],
        state
      )

    on_exit(fn ->
      EctoLibSql.disconnect([], state)
      File.rm(test_db)
      File.rm(test_db <> "-shm")
      File.rm(test_db <> "-wal")
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
      {:ok, _query, _result, state} =
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
      assert {:error, _reason} = EctoLibSql.Native.stmt_column_name(state, stmt_id, count)
      assert {:error, _reason} = EctoLibSql.Native.stmt_column_name(state, stmt_id, 100)

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
      {:ok, _query, _result, state} =
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
      {:ok, _query, result, _state} =
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
      {:ok, _query, result, _state} =
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
      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute("SELECT COUNT(*) FROM users", [], [], state)

      assert [[100]] = result.rows

      # Clear for next benchmark
      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute("DELETE FROM users", [], [], state)

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
  # Statement.reset() - NEW IMPLEMENTATION ✅
  # ============================================================================

  describe "Statement.reset() explicit reset ✅" do
    test "reset_stmt clears statement state explicitly", %{state: state} do
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "INSERT INTO users VALUES (?, ?, ?)")

      # Execute first insertion
      {:ok, _} =
        EctoLibSql.Native.execute_stmt(state, stmt_id, "INSERT INTO users VALUES (?, ?, ?)", [
          1,
          "Alice",
          30
        ])

      # Explicitly reset the statement
      assert :ok = EctoLibSql.Native.reset_stmt(state, stmt_id)

      # Execute second insertion after reset
      {:ok, _} =
        EctoLibSql.Native.execute_stmt(state, stmt_id, "INSERT INTO users VALUES (?, ?, ?)", [
          2,
          "Bob",
          25
        ])

      # Verify both inserts succeeded
      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute("SELECT name FROM users ORDER BY id", [], [], state)

      assert [["Alice"], ["Bob"]] = result.rows

      EctoLibSql.Native.close_stmt(stmt_id)
    end

    test "reset_stmt can be called multiple times", %{state: state} do
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "INSERT INTO users VALUES (?, ?, ?)")

      # Execute and reset multiple times
      for i <- 1..5 do
        {:ok, _} =
          EctoLibSql.Native.execute_stmt(state, stmt_id, "INSERT INTO users VALUES (?, ?, ?)", [
            i,
            "User#{i}",
            20 + i
          ])

        # Explicit reset
        assert :ok = EctoLibSql.Native.reset_stmt(state, stmt_id)
      end

      # Verify all inserts
      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute("SELECT COUNT(*) FROM users", [], [], state)

      assert [[5]] = result.rows

      EctoLibSql.Native.close_stmt(stmt_id)
    end

    test "reset_stmt returns error for invalid statement", %{state: state} do
      # Try to reset non-existent statement
      assert {:error, _reason} = EctoLibSql.Native.reset_stmt(state, "invalid_stmt_id")
    end
  end

  # ============================================================================
  # Statement.get_stmt_columns() - NEW IMPLEMENTATION ✅
  # ============================================================================

  describe "Statement.get_stmt_columns() full metadata ✅" do
    test "get_stmt_columns returns column metadata", %{state: state} do
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "SELECT * FROM users WHERE id = ?")

      # Get full column metadata
      {:ok, columns} = EctoLibSql.Native.get_stmt_columns(state, stmt_id)

      # Should return list of tuples: {name, origin_name, decl_type}
      assert is_list(columns)
      assert length(columns) == 3

      # Verify column metadata structure
      [
        {col1_name, col1_origin, col1_type},
        {col2_name, col2_origin, col2_type},
        {col3_name, col3_origin, col3_type}
      ] = columns

      # Check column 1 (id)
      assert col1_name == "id"
      assert col1_origin == "id"
      assert col1_type == "INTEGER"

      # Check column 2 (name)
      assert col2_name == "name"
      assert col2_origin == "name"
      assert col2_type == "TEXT"

      # Check column 3 (age)
      assert col3_name == "age"
      assert col3_origin == "age"
      assert col3_type == "INTEGER"

      EctoLibSql.Native.close_stmt(stmt_id)
    end

    test "get_stmt_columns works with aliased columns", %{state: state} do
      {:ok, stmt_id} =
        EctoLibSql.Native.prepare(
          state,
          "SELECT id as user_id, name as full_name, age as years FROM users"
        )

      {:ok, columns} = EctoLibSql.Native.get_stmt_columns(state, stmt_id)

      assert length(columns) == 3

      # Check aliased column names
      [{col1_name, _, _}, {col2_name, _, _}, {col3_name, _, _}] = columns

      assert col1_name == "user_id"
      assert col2_name == "full_name"
      assert col3_name == "years"

      EctoLibSql.Native.close_stmt(stmt_id)
    end

    test "get_stmt_columns works with expressions", %{state: state} do
      {:ok, stmt_id} =
        EctoLibSql.Native.prepare(
          state,
          "SELECT COUNT(*) as total, MAX(age) as oldest FROM users"
        )

      {:ok, columns} = EctoLibSql.Native.get_stmt_columns(state, stmt_id)

      assert length(columns) == 2

      [{col1_name, _, _}, {col2_name, _, _}] = columns

      assert col1_name == "total"
      assert col2_name == "oldest"

      EctoLibSql.Native.close_stmt(stmt_id)
    end

    test "get_stmt_columns returns error for invalid statement", %{state: state} do
      # Try to get columns for non-existent statement
      assert {:error, _reason} = EctoLibSql.Native.get_stmt_columns(state, "invalid_stmt_id")
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

    test "parameter_count returns 0 for statements with no parameters", %{state: state} do
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "SELECT * FROM users")

      assert {:ok, 0} = EctoLibSql.Native.stmt_parameter_count(state, stmt_id)

      EctoLibSql.Native.close_stmt(stmt_id)
    end

    test "parameter_count handles many parameters", %{state: state} do
      # Create INSERT statement with 20 parameters
      placeholders = Enum.map(1..20, fn _ -> "?" end) |> Enum.join(", ")
      columns = Enum.map(1..20, fn i -> "col#{i}" end) |> Enum.join(", ")

      # Create table with 20 columns
      create_sql =
        "CREATE TABLE many_cols (#{Enum.map(1..20, fn i -> "col#{i} TEXT" end) |> Enum.join(", ")})"

      {:ok, _query, _result, state} = EctoLibSql.handle_execute(create_sql, [], [], state)

      # Prepare INSERT with 20 parameters
      insert_sql = "INSERT INTO many_cols (#{columns}) VALUES (#{placeholders})"
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, insert_sql)

      assert {:ok, 20} = EctoLibSql.Native.stmt_parameter_count(state, stmt_id)

      EctoLibSql.Native.close_stmt(stmt_id)
    end

    test "parameter_count for UPDATE statements", %{state: state} do
      {:ok, stmt_id} =
        EctoLibSql.Native.prepare(state, "UPDATE users SET name = ?, age = ? WHERE id = ?")

      assert {:ok, 3} = EctoLibSql.Native.stmt_parameter_count(state, stmt_id)

      EctoLibSql.Native.close_stmt(stmt_id)
    end

    test "parameter_count for complex nested queries", %{state: state} do
      # Create posts table for JOIN query
      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER, title TEXT)",
          [],
          [],
          state
        )

      # Complex query with multiple parameters in different parts
      complex_sql = """
      SELECT u.name, COUNT(p.id) as post_count
      FROM users u
      LEFT JOIN posts p ON u.id = p.user_id
      WHERE u.age > ? AND u.name LIKE ?
      GROUP BY u.id
      HAVING COUNT(p.id) >= ?
      """

      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, complex_sql)

      assert {:ok, 3} = EctoLibSql.Native.stmt_parameter_count(state, stmt_id)

      EctoLibSql.Native.close_stmt(stmt_id)
    end

    test "parameter_name introspection for named parameters", %{state: state} do
      # Test with colon-style named parameters (:name)
      {:ok, stmt_id} =
        EctoLibSql.Native.prepare(
          state,
          "INSERT INTO users (id, name, age) VALUES (:id, :name, :age)"
        )

      # Get parameter names (note: SQLite uses 1-based indexing)
      {:ok, param1} = EctoLibSql.Native.stmt_parameter_name(state, stmt_id, 1)
      assert param1 == ":id"

      {:ok, param2} = EctoLibSql.Native.stmt_parameter_name(state, stmt_id, 2)
      assert param2 == ":name"

      {:ok, param3} = EctoLibSql.Native.stmt_parameter_name(state, stmt_id, 3)
      assert param3 == ":age"

      EctoLibSql.Native.close_stmt(stmt_id)
    end

    test "parameter_name returns nil for positional parameters", %{state: state} do
      {:ok, stmt_id} =
        EctoLibSql.Native.prepare(state, "SELECT * FROM users WHERE name = ? AND age = ?")

      # Positional parameters should return nil
      {:ok, param1} = EctoLibSql.Native.stmt_parameter_name(state, stmt_id, 1)
      assert param1 == nil

      {:ok, param2} = EctoLibSql.Native.stmt_parameter_name(state, stmt_id, 2)
      assert param2 == nil

      EctoLibSql.Native.close_stmt(stmt_id)
    end

    test "parameter_name supports dollar-style parameters", %{state: state} do
      # Test with dollar-style named parameters ($name)
      {:ok, stmt_id} =
        EctoLibSql.Native.prepare(state, "SELECT * FROM users WHERE id = $id AND name = $name")

      {:ok, param1} = EctoLibSql.Native.stmt_parameter_name(state, stmt_id, 1)
      assert param1 == "$id"

      {:ok, param2} = EctoLibSql.Native.stmt_parameter_name(state, stmt_id, 2)
      assert param2 == "$name"

      EctoLibSql.Native.close_stmt(stmt_id)
    end

    test "parameter_name supports at-style parameters", %{state: state} do
      # Test with at-style named parameters (@name)
      {:ok, stmt_id} =
        EctoLibSql.Native.prepare(state, "SELECT * FROM users WHERE id = @id AND name = @name")

      {:ok, param1} = EctoLibSql.Native.stmt_parameter_name(state, stmt_id, 1)
      assert param1 == "@id"

      {:ok, param2} = EctoLibSql.Native.stmt_parameter_name(state, stmt_id, 2)
      assert param2 == "@name"

      EctoLibSql.Native.close_stmt(stmt_id)
    end

    test "parameter_name handles mixed positional and named parameters", %{state: state} do
      # SQLite allows mixing positional and named parameters
      {:ok, stmt_id} =
        EctoLibSql.Native.prepare(state, "SELECT * FROM users WHERE id = :id AND age > ?")

      {:ok, param1} = EctoLibSql.Native.stmt_parameter_name(state, stmt_id, 1)
      assert param1 == ":id"

      {:ok, param2} = EctoLibSql.Native.stmt_parameter_name(state, stmt_id, 2)
      assert param2 == nil

      EctoLibSql.Native.close_stmt(stmt_id)
    end
  end

  # ============================================================================
  # Column introspection edge cases
  # ============================================================================

  describe "Column introspection edge cases ✅" do
    test "column count for SELECT *", %{state: state} do
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "SELECT * FROM users")

      # Should return 3 columns (id, name, age)
      assert {:ok, 3} = EctoLibSql.Native.stmt_column_count(state, stmt_id)

      EctoLibSql.Native.close_stmt(stmt_id)
    end

    test "column count for INSERT without RETURNING", %{state: state} do
      {:ok, stmt_id} =
        EctoLibSql.Native.prepare(state, "INSERT INTO users VALUES (?, ?, ?)")

      # INSERT without RETURNING should return 0 columns
      assert {:ok, 0} = EctoLibSql.Native.stmt_column_count(state, stmt_id)

      EctoLibSql.Native.close_stmt(stmt_id)
    end

    test "column count for UPDATE without RETURNING", %{state: state} do
      {:ok, stmt_id} =
        EctoLibSql.Native.prepare(state, "UPDATE users SET name = ? WHERE id = ?")

      # UPDATE without RETURNING should return 0 columns
      assert {:ok, 0} = EctoLibSql.Native.stmt_column_count(state, stmt_id)

      EctoLibSql.Native.close_stmt(stmt_id)
    end

    test "column count for DELETE without RETURNING", %{state: state} do
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "DELETE FROM users WHERE id = ?")

      # DELETE without RETURNING should return 0 columns
      assert {:ok, 0} = EctoLibSql.Native.stmt_column_count(state, stmt_id)

      EctoLibSql.Native.close_stmt(stmt_id)
    end

    test "column metadata for aggregate functions", %{state: state} do
      {:ok, stmt_id} =
        EctoLibSql.Native.prepare(
          state,
          """
          SELECT
            COUNT(*) as total,
            AVG(age) as avg_age,
            MIN(age) as min_age,
            MAX(age) as max_age,
            SUM(age) as sum_age
          FROM users
          """
        )

      assert {:ok, 5} = EctoLibSql.Native.stmt_column_count(state, stmt_id)

      # Check column names
      names = get_column_names(state, stmt_id, 5)
      assert names == ["total", "avg_age", "min_age", "max_age", "sum_age"]

      EctoLibSql.Native.close_stmt(stmt_id)
    end

    test "column metadata for JOIN with multiple tables", %{state: state} do
      # Create posts table
      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER, title TEXT, content TEXT)",
          [],
          [],
          state
        )

      # Complex JOIN query
      {:ok, stmt_id} =
        EctoLibSql.Native.prepare(
          state,
          """
          SELECT
            u.id,
            u.name,
            u.age,
            p.id as post_id,
            p.title,
            p.content
          FROM users u
          INNER JOIN posts p ON u.id = p.user_id
          """
        )

      assert {:ok, 6} = EctoLibSql.Native.stmt_column_count(state, stmt_id)

      names = get_column_names(state, stmt_id, 6)
      assert names == ["id", "name", "age", "post_id", "title", "content"]

      EctoLibSql.Native.close_stmt(stmt_id)
    end

    test "column metadata for subqueries", %{state: state} do
      {:ok, stmt_id} =
        EctoLibSql.Native.prepare(
          state,
          """
          SELECT
            name,
            (SELECT COUNT(*) FROM users) as total_users
          FROM users
          WHERE id = ?
          """
        )

      assert {:ok, 2} = EctoLibSql.Native.stmt_column_count(state, stmt_id)

      names = get_column_names(state, stmt_id, 2)
      assert names == ["name", "total_users"]

      EctoLibSql.Native.close_stmt(stmt_id)
    end

    test "column metadata for computed expressions", %{state: state} do
      {:ok, stmt_id} =
        EctoLibSql.Native.prepare(
          state,
          """
          SELECT
            id,
            name,
            age * 2 as double_age,
            UPPER(name) as upper_name,
            age + 10 as age_plus_ten
          FROM users
          """
        )

      assert {:ok, 5} = EctoLibSql.Native.stmt_column_count(state, stmt_id)

      names = get_column_names(state, stmt_id, 5)
      assert names == ["id", "name", "double_age", "upper_name", "age_plus_ten"]

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
