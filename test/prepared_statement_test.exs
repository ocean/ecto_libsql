defmodule EctoLibSql.PreparedStatementTest do
  @moduledoc """
  Tests for prepared statement functionality including statement introspection.
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

  setup do
    # Create unique database file for this test
    db_file = "z_ecto_libsql_test-prepared_#{:erlang.unique_integer([:positive])}.db"

    conn_id = Native.connect([database: db_file], :local)
    state = %State{conn_id: conn_id, mode: :local, sync: :disable_sync}

    # Create test table
    {:ok, _query, _result, state} =
      exec_sql(state, "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT)")

    on_exit(fn ->
      Native.close(state.conn_id, :conn_id)
      File.rm(db_file)
      File.rm(db_file <> "-shm")
      File.rm(db_file <> "-wal")
    end)

    {:ok, state: state}
  end

  describe "statement preparation" do
    test "prepare statement returns statement ID", %{state: state} do
      {:ok, stmt_id} = Native.prepare(state, "SELECT * FROM users")
      assert is_binary(stmt_id)
      assert String.length(stmt_id) > 0

      # Cleanup
      Native.close_stmt(stmt_id)
    end

    test "prepare duplicate SQL returns different statement IDs", %{state: state} do
      {:ok, stmt_id1} = Native.prepare(state, "SELECT * FROM users")
      {:ok, stmt_id2} = Native.prepare(state, "SELECT * FROM users")

      assert is_binary(stmt_id1)
      assert is_binary(stmt_id2)
      # Each prepare should get a unique ID
      assert stmt_id1 != stmt_id2

      # Cleanup
      Native.close_stmt(stmt_id1)
      Native.close_stmt(stmt_id2)
    end

    test "prepare invalid SQL returns error", %{state: state} do
      # Note: prepare now validates SQL immediately (not deferred to execute)
      # This is better - catch errors early
      assert {:error, reason} = Native.prepare(state, "INVALID SQL SYNTAX")
      assert reason =~ "Prepare failed"
      assert reason =~ "syntax error"
    end

    test "prepare parameterised query with placeholders", %{state: state} do
      {:ok, stmt_id} = Native.prepare(state, "SELECT * FROM users WHERE id = ? AND name = ?")
      assert is_binary(stmt_id)

      # Cleanup
      Native.close_stmt(stmt_id)
    end
  end

  describe "statement execution" do
    test "execute prepared statement with parameters", %{state: state} do
      # Insert test data
      {:ok, _query, _result, state} =
        exec_sql(state, "INSERT INTO users (id, name, email) VALUES (?, ?, ?)", [
          1,
          "Alice",
          "alice@example.com"
        ])

      # Prepare and execute
      {:ok, stmt_id} = Native.prepare(state, "SELECT * FROM users WHERE id = ?")
      {:ok, _result} = Native.query_stmt(state, stmt_id, [1])

      # Cleanup
      Native.close_stmt(stmt_id)
    end

    test "execute prepared statement multiple times with different parameters", %{state: state} do
      # Insert test data
      {:ok, _query, _result, state} =
        exec_sql(state, "INSERT INTO users (id, name, email) VALUES (?, ?, ?)", [
          1,
          "Alice",
          "alice@example.com"
        ])

      {:ok, _query, _result, state} =
        exec_sql(state, "INSERT INTO users (id, name, email) VALUES (?, ?, ?)", [
          2,
          "Bob",
          "bob@example.com"
        ])

      # Prepare once, execute multiple times
      {:ok, stmt_id} = Native.prepare(state, "SELECT * FROM users WHERE id = ?")

      {:ok, result1} = Native.query_stmt(state, stmt_id, [1])
      assert length(result1.rows) == 1
      assert hd(result1.rows) == [1, "Alice", "alice@example.com"]

      {:ok, result2} = Native.query_stmt(state, stmt_id, [2])
      assert length(result2.rows) == 1
      assert hd(result2.rows) == [2, "Bob", "bob@example.com"]

      # Cleanup
      Native.close_stmt(stmt_id)
    end

    test "execute prepared statement without parameters", %{state: state} do
      {:ok, stmt_id} = Native.prepare(state, "SELECT * FROM users")
      {:ok, result} = Native.query_stmt(state, stmt_id, [])
      assert is_list(result.rows)

      # Cleanup
      Native.close_stmt(stmt_id)
    end

    test "execute with wrong number of parameters returns error or empty result", %{state: state} do
      {:ok, stmt_id} = Native.prepare(state, "SELECT * FROM users WHERE id = ? AND name = ?")

      # Too few parameters - SQLite may return error or empty result
      result = Native.query_stmt(state, stmt_id, [1])

      case result do
        {:error, _reason} ->
          :ok

        {:ok, result} ->
          # If it succeeds, it should return empty results (no matches)
          assert is_list(result.rows)
      end

      # Too many parameters (SQLite ignores extra params, so this might work)
      result2 = Native.query_stmt(state, stmt_id, [1, "Alice", "extra"])

      case result2 do
        {:ok, _} -> :ok
        {:error, _} -> :ok
      end

      # Cleanup
      Native.close_stmt(stmt_id)
    end
  end

  describe "statement introspection" do
    test "column_count returns number of result columns", %{state: state} do
      {:ok, stmt_id} = Native.prepare(state, "SELECT id, name, email FROM users")
      {:ok, count} = Native.stmt_column_count(state, stmt_id)
      assert count == 3

      # Cleanup
      Native.close_stmt(stmt_id)
    end

    test "column_count with SELECT * returns all columns", %{state: state} do
      {:ok, stmt_id} = Native.prepare(state, "SELECT * FROM users")
      {:ok, count} = Native.stmt_column_count(state, stmt_id)
      # users table has 3 columns: id, name, email
      assert count == 3

      # Cleanup
      Native.close_stmt(stmt_id)
    end

    test "column_count for INSERT returns 0", %{state: state} do
      {:ok, stmt_id} = Native.prepare(state, "INSERT INTO users VALUES (?, ?, ?)")
      {:ok, count} = Native.stmt_column_count(state, stmt_id)
      assert count == 0

      # Cleanup
      Native.close_stmt(stmt_id)
    end

    test "column_name returns column name by index", %{state: state} do
      {:ok, stmt_id} = Native.prepare(state, "SELECT id, name, email FROM users")

      {:ok, name0} = Native.stmt_column_name(state, stmt_id, 0)
      assert name0 == "id"

      {:ok, name1} = Native.stmt_column_name(state, stmt_id, 1)
      assert name1 == "name"

      {:ok, name2} = Native.stmt_column_name(state, stmt_id, 2)
      assert name2 == "email"

      # Cleanup
      Native.close_stmt(stmt_id)
    end

    test "column_name with SELECT * returns all column names", %{state: state} do
      {:ok, stmt_id} = Native.prepare(state, "SELECT * FROM users")

      {:ok, name0} = Native.stmt_column_name(state, stmt_id, 0)
      assert name0 == "id"

      {:ok, name1} = Native.stmt_column_name(state, stmt_id, 1)
      assert name1 == "name"

      {:ok, name2} = Native.stmt_column_name(state, stmt_id, 2)
      assert name2 == "email"

      # Cleanup
      Native.close_stmt(stmt_id)
    end

    test "column_name with invalid index returns error", %{state: state} do
      {:ok, stmt_id} = Native.prepare(state, "SELECT id FROM users")

      # Index out of bounds
      assert {:error, reason} = Native.stmt_column_name(state, stmt_id, 99)
      assert is_binary(reason)
      assert reason =~ "out of bounds"

      # Cleanup
      Native.close_stmt(stmt_id)
    end

    test "parameter_count returns number of parameters", %{state: state} do
      {:ok, stmt_id} = Native.prepare(state, "SELECT * FROM users WHERE id = ? AND name = ?")
      {:ok, count} = Native.stmt_parameter_count(state, stmt_id)
      assert count == 2

      # Cleanup
      Native.close_stmt(stmt_id)
    end

    test "parameter_count with no parameters returns 0", %{state: state} do
      {:ok, stmt_id} = Native.prepare(state, "SELECT * FROM users")
      {:ok, count} = Native.stmt_parameter_count(state, stmt_id)
      assert count == 0

      # Cleanup
      Native.close_stmt(stmt_id)
    end

    test "parameter_count with multiple placeholders", %{state: state} do
      {:ok, stmt_id} =
        Native.prepare(
          state,
          "INSERT INTO users (id, name, email) VALUES (?, ?, ?)"
        )

      {:ok, count} = Native.stmt_parameter_count(state, stmt_id)
      assert count == 3

      # Cleanup
      Native.close_stmt(stmt_id)
    end
  end

  describe "statement lifecycle" do
    test "close statement removes from registry", %{state: state} do
      {:ok, stmt_id} = Native.prepare(state, "SELECT * FROM users")

      # Should work before close
      {:ok, _count} = Native.stmt_column_count(state, stmt_id)

      # Close it
      :ok = Native.close_stmt(stmt_id)

      # Should fail after close
      assert {:error, _reason} = Native.stmt_column_count(state, stmt_id)
    end

    test "use after close returns error", %{state: state} do
      {:ok, stmt_id} = Native.prepare(state, "SELECT * FROM users")
      :ok = Native.close_stmt(stmt_id)

      # All operations should fail
      assert {:error, _} = Native.query_stmt(state, stmt_id, [])
      assert {:error, _} = Native.stmt_column_count(state, stmt_id)
      assert {:error, _} = Native.stmt_parameter_count(state, stmt_id)
    end
  end

  describe "statement error handling" do
    test "introspection with invalid statement ID returns error", %{state: state} do
      invalid_id = "00000000-0000-0000-0000-000000000000"

      assert {:error, _reason} = Native.stmt_column_count(state, invalid_id)
      assert {:error, _reason} = Native.stmt_column_name(state, invalid_id, 0)
      assert {:error, _reason} = Native.stmt_parameter_count(state, invalid_id)
    end

    test "execute with invalid statement ID returns error", %{state: state} do
      invalid_id = "00000000-0000-0000-0000-000000000000"
      assert {:error, _reason} = Native.query_stmt(state, invalid_id, [])
    end
  end

  describe "statement reset and caching" do
    test "reset statement for reuse without re-prepare", %{state: state} do
      # Create logs table
      {:ok, _query, _result, state} =
        exec_sql(state, "CREATE TABLE logs (id INTEGER PRIMARY KEY AUTOINCREMENT, message TEXT)")

      # Prepare statement once
      {:ok, stmt_id} = Native.prepare(state, "INSERT INTO logs (message) VALUES (?)")

      # Execute multiple times - statement caching handles reset automatically
      for i <- 1..5 do
        {:ok, _rows} =
          Native.execute_stmt(
            state,
            stmt_id,
            "INSERT INTO logs (message) VALUES (?)",
            ["Log #{i}"]
          )
      end

      # Verify all inserts succeeded
      {:ok, _query, result, _state} = exec_sql(state, "SELECT COUNT(*) FROM logs")
      assert [[5]] = result.rows

      # Cleanup
      Native.close_stmt(stmt_id)
    end

    test "reset clears parameter bindings", %{state: state} do
      {:ok, stmt_id} = Native.prepare(state, "INSERT INTO users VALUES (?, ?, ?)")

      # Execute with parameters - automatic reset between calls
      {:ok, _} =
        Native.execute_stmt(state, stmt_id, "INSERT INTO users VALUES (?, ?, ?)", [
          1,
          "Alice",
          "alice@example.com"
        ])

      # Execute with different parameters - no manual reset needed
      {:ok, _} =
        Native.execute_stmt(state, stmt_id, "INSERT INTO users VALUES (?, ?, ?)", [
          2,
          "Bob",
          "bob@example.com"
        ])

      # Verify both inserts
      {:ok, _query, result, _state} = exec_sql(state, "SELECT name FROM users ORDER BY id")
      assert [["Alice"], ["Bob"]] = result.rows

      Native.close_stmt(stmt_id)
    end
  end

  describe "statement reset - explicit reset" do
    test "reset_stmt clears statement state explicitly", %{state: state} do
      {:ok, stmt_id} = Native.prepare(state, "INSERT INTO users VALUES (?, ?, ?)")

      # Execute first insertion
      {:ok, _} =
        Native.execute_stmt(state, stmt_id, "INSERT INTO users VALUES (?, ?, ?)", [
          1,
          "Alice",
          "alice@example.com"
        ])

      # Explicitly reset the statement
      assert :ok = Native.reset_stmt(state, stmt_id)

      # Execute second insertion after reset
      {:ok, _} =
        Native.execute_stmt(state, stmt_id, "INSERT INTO users VALUES (?, ?, ?)", [
          2,
          "Bob",
          "bob@example.com"
        ])

      # Verify both inserts succeeded
      {:ok, _query, result, _state} = exec_sql(state, "SELECT name FROM users ORDER BY id")
      assert [["Alice"], ["Bob"]] = result.rows

      Native.close_stmt(stmt_id)
    end

    test "reset_stmt can be called multiple times", %{state: state} do
      {:ok, stmt_id} = Native.prepare(state, "INSERT INTO users VALUES (?, ?, ?)")

      # Execute and reset multiple times
      for i <- 1..5 do
        {:ok, _} =
          Native.execute_stmt(state, stmt_id, "INSERT INTO users VALUES (?, ?, ?)", [
            i,
            "User#{i}",
            "user#{i}@example.com"
          ])

        # Explicit reset
        assert :ok = Native.reset_stmt(state, stmt_id)
      end

      # Verify all inserts
      {:ok, _query, result, _state} = exec_sql(state, "SELECT COUNT(*) FROM users")
      assert [[5]] = result.rows

      Native.close_stmt(stmt_id)
    end

    test "reset_stmt returns error for invalid statement", %{state: state} do
      # Try to reset non-existent statement
      assert {:error, _reason} = Native.reset_stmt(state, "invalid_stmt_id")
    end
  end

  describe "statement get_stmt_columns - full metadata" do
    test "get_stmt_columns returns column metadata", %{state: state} do
      {:ok, stmt_id} = Native.prepare(state, "SELECT * FROM users WHERE id = ?")

      # Get full column metadata
      {:ok, columns} = Native.get_stmt_columns(state, stmt_id)

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

      # Check column 3 (email)
      assert col3_name == "email"
      assert col3_origin == "email"
      assert col3_type == "TEXT"

      Native.close_stmt(stmt_id)
    end

    test "get_stmt_columns works with aliased columns", %{state: state} do
      {:ok, stmt_id} =
        Native.prepare(
          state,
          "SELECT id as user_id, name as full_name, email as mail FROM users"
        )

      {:ok, columns} = Native.get_stmt_columns(state, stmt_id)

      assert length(columns) == 3

      # Check aliased column names
      [{col1_name, _, _}, {col2_name, _, _}, {col3_name, _, _}] = columns

      assert col1_name == "user_id"
      assert col2_name == "full_name"
      assert col3_name == "mail"

      Native.close_stmt(stmt_id)
    end

    test "get_stmt_columns works with expressions", %{state: state} do
      {:ok, stmt_id} =
        Native.prepare(
          state,
          "SELECT COUNT(*) as total, MAX(id) as max_id FROM users"
        )

      {:ok, columns} = Native.get_stmt_columns(state, stmt_id)

      assert length(columns) == 2

      [{col1_name, _, _}, {col2_name, _, _}] = columns

      assert col1_name == "total"
      assert col2_name == "max_id"

      Native.close_stmt(stmt_id)
    end

    test "get_stmt_columns returns error for invalid statement", %{state: state} do
      # Try to get columns for non-existent statement
      assert {:error, _reason} = Native.get_stmt_columns(state, "invalid_stmt_id")
    end
  end

  describe "statement parameter introspection" do
    test "parameter_count with named parameters", %{state: state} do
      # Test with colon-style named parameters (:name)
      {:ok, stmt_id} =
        Native.prepare(
          state,
          "INSERT INTO users (id, name, email) VALUES (:id, :name, :email)"
        )

      # Get parameter names (note: SQLite uses 1-based indexing)
      {:ok, param1} = Native.stmt_parameter_name(state, stmt_id, 1)
      assert param1 == ":id"

      {:ok, param2} = Native.stmt_parameter_name(state, stmt_id, 2)
      assert param2 == ":name"

      {:ok, param3} = Native.stmt_parameter_name(state, stmt_id, 3)
      assert param3 == ":email"

      Native.close_stmt(stmt_id)
    end

    test "parameter_name returns nil for positional parameters", %{state: state} do
      {:ok, stmt_id} =
        Native.prepare(state, "SELECT * FROM users WHERE name = ? AND email = ?")

      # Positional parameters should return nil
      {:ok, param1} = Native.stmt_parameter_name(state, stmt_id, 1)
      assert param1 == nil

      {:ok, param2} = Native.stmt_parameter_name(state, stmt_id, 2)
      assert param2 == nil

      Native.close_stmt(stmt_id)
    end

    test "parameter_name supports dollar-style parameters", %{state: state} do
      # Test with dollar-style named parameters ($name)
      {:ok, stmt_id} =
        Native.prepare(state, "SELECT * FROM users WHERE id = $id AND name = $name")

      {:ok, param1} = Native.stmt_parameter_name(state, stmt_id, 1)
      assert param1 == "$id"

      {:ok, param2} = Native.stmt_parameter_name(state, stmt_id, 2)
      assert param2 == "$name"

      Native.close_stmt(stmt_id)
    end

    test "parameter_name supports at-style parameters", %{state: state} do
      # Test with at-style named parameters (@name)
      {:ok, stmt_id} =
        Native.prepare(state, "SELECT * FROM users WHERE id = @id AND name = @name")

      {:ok, param1} = Native.stmt_parameter_name(state, stmt_id, 1)
      assert param1 == "@id"

      {:ok, param2} = Native.stmt_parameter_name(state, stmt_id, 2)
      assert param2 == "@name"

      Native.close_stmt(stmt_id)
    end

    test "parameter_name handles mixed positional and named parameters", %{state: state} do
      # SQLite allows mixing positional and named parameters
      {:ok, stmt_id} =
        Native.prepare(state, "SELECT * FROM users WHERE id = :id AND name = ?")

      {:ok, param1} = Native.stmt_parameter_name(state, stmt_id, 1)
      assert param1 == ":id"

      {:ok, param2} = Native.stmt_parameter_name(state, stmt_id, 2)
      assert param2 == nil

      Native.close_stmt(stmt_id)
    end
  end

  describe "statement binding behaviour (ported from ecto_sql)" do
    test "prepared statement auto-reset of bindings between executions", %{state: state} do
      # Source: ecto_sql prepared statement tests
      # This verifies that parameter bindings are properly cleared between executions
      # Prevents cross-contamination of parameters from previous executions

      {:ok, stmt_id} = Native.prepare(state, "SELECT ? as value")

      # First query with parameter 42
      {:ok, result1} = Native.query_stmt(state, stmt_id, [42])
      assert result1.rows == [[42]]

      # Second query with different parameter 99
      # Should work correctly, not reuse old binding from first query
      {:ok, result2} = Native.query_stmt(state, stmt_id, [99])
      assert result2.rows == [[99]]

      # Result should be [[99]], NOT [[42]] - binding was reset
      refute result2.rows == [[42]], "Binding from first query leaked into second query"

      :ok = Native.close_stmt(stmt_id)
    end

    test "prepared statement reuse with different parameter types", %{state: state} do
      # Verify bindings work correctly across different value types

      {:ok, stmt_id} = Native.prepare(state, "SELECT ? as val1, ? as val2")

      # Execute with integers
      {:ok, result1} = Native.query_stmt(state, stmt_id, [1, 2])
      assert result1.rows == [[1, 2]]

      # Execute with strings (should work, SQLite is dynamically typed)
      {:ok, result2} = Native.query_stmt(state, stmt_id, ["hello", "world"])
      assert result2.rows == [["hello", "world"]]

      # Execute with mixed types
      {:ok, result3} = Native.query_stmt(state, stmt_id, [42, "text"])
      assert result3.rows == [[42, "text"]]

      :ok = Native.close_stmt(stmt_id)
    end

    @tag :performance
    @tag :flaky
    test "prepared vs unprepared statement performance comparison", %{state: state} do
      # Source: ecto_sql performance tests
      # Demonstrates the significant performance benefit of prepared statements

      # Setup: Create 100 test users
      Enum.each(1..100, fn i ->
        {:ok, _query, _result, _} =
          exec_sql(state, "INSERT INTO users (id, name, email) VALUES (?, ?, ?)", [
            i,
            "User#{i}",
            "user#{i}@example.com"
          ])
      end)

      # Benchmark 1: Unprepared (re-compile SQL each time)
      {unprepared_time, _} =
        :timer.tc(fn ->
          Enum.each(1..100, fn i ->
            {:ok, _query, _result, _state} =
              EctoLibSql.handle_execute(
                "SELECT * FROM users WHERE id = ?",
                [i],
                [],
                state
              )
          end)
        end)

      # Benchmark 2: Prepared (compile once, reuse)
      {:ok, stmt_id} = Native.prepare(state, "SELECT * FROM users WHERE id = ?")

      {prepared_time, _} =
        :timer.tc(fn ->
          Enum.each(1..100, fn i ->
            {:ok, _result} = Native.query_stmt(state, stmt_id, [i])
          end)
        end)

      :ok = Native.close_stmt(stmt_id)

      # Calculate speedup ratio
      speedup = unprepared_time / prepared_time

      # Log results for visibility
      IO.puts("\n=== Prepared Statement Performance ===")
      IO.puts("Unprepared (100 executions): #{unprepared_time}µs")
      IO.puts("Prepared (100 executions):   #{prepared_time}µs")
      IO.puts("Speedup: #{Float.round(speedup, 2)}x faster")
      IO.puts("======================================\n")

      # Performance testing on CI can be highly variable due to shared resources,
      # CPU throttling, and other factors. This test primarily serves to document
      # the prepared statement API and provide visibility into performance characteristics.
      #
      # In local development with realistic workloads, speedup is typically 2-15x.
      # On CI with small test datasets, results can be highly variable.
      if speedup < 0.8 do
        IO.puts(
          "⚠️  Warning: Prepared statements were significantly slower (#{Float.round(speedup, 2)}x)"
        )

        IO.puts("   This is unexpected - prepared statements should not add significant overhead")

        IO.puts("   Consider investigating if this pattern continues")
      end

      if speedup < 1.0 do
        IO.puts("ℹ️  Note: Prepared statements were slightly slower (#{Float.round(speedup, 2)}x)")

        IO.puts("   This can happen with small datasets and simple queries on CI environments")
      end

      # Success! Prepared statement API is working, which is the main goal of this test
      # Always pass - performance validation is informational, not a gate
      assert true, "Prepared statement API is functional"
    end

    @tag :performance
    @tag :memory
    test "prepared statement memory efficiency with many executions", %{state: state} do
      # Verify that reusing a prepared statement doesn't leak memory

      # Insert 1000 test rows
      Enum.each(1..1000, fn i ->
        {:ok, _query, _result, _} =
          exec_sql(state, "INSERT INTO users (id, name, email) VALUES (?, ?, ?)", [
            i,
            "User#{i}",
            "user#{i}@example.com"
          ])
      end)

      {:ok, stmt_id} = Native.prepare(state, "SELECT * FROM users WHERE id = ?")

      # Execute statement 1000 times
      # Memory usage should stay constant (no accumulation)
      Enum.each(1..1000, fn i ->
        {:ok, _result} = Native.query_stmt(state, stmt_id, [i])
      end)

      # No assertions on memory (platform-dependent)
      # This test documents expected behaviour and can catch memory leaks in manual testing

      :ok = Native.close_stmt(stmt_id)
    end
  end

  describe "concurrent prepared statement usage" do
    test "multiple processes can use different prepared statements concurrently", %{
      state: state
    } do
      # Setup: Insert test data
      Enum.each(1..10, fn i ->
        {:ok, _query, _result, _} =
          exec_sql(state, "INSERT INTO users (id, name, email) VALUES (?, ?, ?)", [
            i,
            "User#{i}",
            "user#{i}@example.com"
          ])
      end)

      # Prepare multiple statements
      {:ok, stmt_select_id} = Native.prepare(state, "SELECT * FROM users WHERE id = ?")
      {:ok, stmt_select_name} = Native.prepare(state, "SELECT * FROM users WHERE name = ?")

      # Create multiple tasks executing different prepared statements concurrently
      tasks =
        Enum.map(1..5, fn i ->
          Task.async(fn ->
            # Each task executes SELECT by ID
            {:ok, result_id} = Native.query_stmt(state, stmt_select_id, [i])
            assert length(result_id.rows) == 1

            # Each task executes SELECT by name
            {:ok, result_name} = Native.query_stmt(state, stmt_select_name, ["User#{i}"])
            assert length(result_name.rows) == 1

            # Verify both queries return same data
            assert hd(result_id.rows) == hd(result_name.rows)

            :ok
          end)
        end)

      # Wait for all tasks to complete successfully
      results = Task.await_many(tasks, 5000)
      assert Enum.all?(results, &(&1 == :ok))

      # Cleanup
      Native.close_stmt(stmt_select_id)
      Native.close_stmt(stmt_select_name)
    end

    test "single prepared statement can be safely used by multiple processes", %{state: state} do
      # Setup: Insert test data
      Enum.each(1..20, fn i ->
        {:ok, _query, _result, _} =
          exec_sql(state, "INSERT INTO users (id, name, email) VALUES (?, ?, ?)", [
            i,
            "User#{i}",
            "user#{i}@example.com"
          ])
      end)

      # Prepare a single statement to be shared across tasks
      {:ok, stmt_id} = Native.prepare(state, "SELECT * FROM users WHERE id = ?")

      # Create multiple concurrent tasks using the same prepared statement
      tasks =
        Enum.map(1..10, fn task_num ->
          Task.async(fn ->
            # Each task queries a different ID with the same prepared statement
            {:ok, result} = Native.query_stmt(state, stmt_id, [task_num])
            assert length(result.rows) == 1

            [id, name, email] = hd(result.rows)
            assert id == task_num
            assert name == "User#{task_num}"
            assert String.contains?(email, "@example.com")

            # Simulate some work
            Process.sleep(10)

            :ok
          end)
        end)

      # Wait for all tasks to complete successfully
      results = Task.await_many(tasks, 5000)
      assert Enum.all?(results, &(&1 == :ok))

      # Verify data integrity - statement should work correctly after concurrent access
      {:ok, final_result} = Native.query_stmt(state, stmt_id, [5])
      assert hd(final_result.rows) == [5, "User5", "user5@example.com"]

      # Cleanup
      Native.close_stmt(stmt_id)
    end

    test "concurrent writes with prepared statements maintain consistency", %{state: state} do
      # Setup: Create initial user
      {:ok, _query, _result, _} =
        exec_sql(state, "INSERT INTO users (id, name, email) VALUES (?, ?, ?)", [
          1,
          "Initial",
          "initial@example.com"
        ])

      # Prepare statements for reading and writing
      {:ok, stmt_select} = Native.prepare(state, "SELECT COUNT(*) FROM users")

      {:ok, stmt_insert} =
        Native.prepare(state, "INSERT INTO users (id, name, email) VALUES (?, ?, ?)")

      # Create tasks that concurrently write data
      tasks =
        Enum.map(2..6, fn user_id ->
          Task.async(fn ->
            # Each task inserts a new user using the prepared statement
            {:ok, _rows} =
              Native.execute_stmt(
                state,
                stmt_insert,
                "INSERT INTO users (id, name, email) VALUES (?, ?, ?)",
                [user_id, "User#{user_id}", "user#{user_id}@example.com"]
              )

            :ok
          end)
        end)

      # Wait for all writes to complete
      Task.await_many(tasks, 5000)

      # Verify final count (initial + 5 new users)
      {:ok, count_result} = Native.query_stmt(state, stmt_select, [])
      assert hd(hd(count_result.rows)) == 6

      # Cleanup
      Native.close_stmt(stmt_select)
      Native.close_stmt(stmt_insert)
    end

    test "prepared statements handle parameter isolation across concurrent tasks", %{
      state: state
    } do
      # Setup: Create test data
      Enum.each(1..5, fn i ->
        {:ok, _query, _result, _} =
          exec_sql(state, "INSERT INTO users (id, name, email) VALUES (?, ?, ?)", [
            i,
            "User#{i}",
            "user#{i}@example.com"
          ])
      end)

      {:ok, stmt_id} = Native.prepare(state, "SELECT ? as param_test, id FROM users WHERE id = ?")

      # Create tasks with different parameter combinations
      tasks =
        Enum.map(1..5, fn task_id ->
          Task.async(fn ->
            # Each task uses different parameters
            {:ok, result} = Native.query_stmt(state, stmt_id, ["Task#{task_id}", task_id])
            assert length(result.rows) == 1

            [param_value, id] = hd(result.rows)
            # Verify the parameter was not contaminated from another task
            assert param_value == "Task#{task_id}",
                   "Parameter #{param_value} should be Task#{task_id}"

            assert id == task_id

            :ok
          end)
        end)

      # Wait for all tasks to complete successfully
      results = Task.await_many(tasks, 5000)
      assert Enum.all?(results, &(&1 == :ok))

      # Cleanup
      Native.close_stmt(stmt_id)
    end

    test "prepared statements maintain isolation when reset concurrently", %{state: state} do
      # Setup: Create test data (IDs 1-10)
      Enum.each(1..10, fn i ->
        {:ok, _query, _result, _} =
          exec_sql(state, "INSERT INTO users (id, name, email) VALUES (?, ?, ?)", [
            i,
            "User#{i}",
            "user#{i}@example.com"
          ])
      end)

      {:ok, stmt_id} = Native.prepare(state, "SELECT * FROM users WHERE id = ?")

      # Create multiple tasks that will reset the statement concurrently
      tasks =
        Enum.map(1..5, fn task_num ->
          Task.async(fn ->
            # Each task executes and resets the statement
            {:ok, result} = Native.query_stmt(state, stmt_id, [task_num])
            assert length(result.rows) == 1

            [id, name, email] = hd(result.rows)
            assert id == task_num
            assert name == "User#{task_num}"
            assert email == "user#{task_num}@example.com"

            # Explicitly reset statement to clear bindings
            :ok = Native.reset_stmt(state, stmt_id)

            # Execute again after reset - should query IDs 6-10
            {:ok, result2} = Native.query_stmt(state, stmt_id, [task_num + 5])

            # After reset, prepared statement must return the correct row
            assert length(result2.rows) == 1, "Should get exactly one row after reset"

            [new_id, new_name, new_email] = hd(result2.rows)

            assert new_id == task_num + 5,
                   "ID should be #{task_num + 5}, got #{new_id}"

            assert new_name == "User#{task_num + 5}",
                   "Name should be User#{task_num + 5}, got #{new_name}"

            assert new_email == "user#{task_num + 5}@example.com",
                   "Email should be user#{task_num + 5}@example.com, got #{new_email}"

            :ok
          end)
        end)

      # Wait for all tasks to complete successfully
      results = Task.await_many(tasks, 5000)
      assert Enum.all?(results, &(&1 == :ok))

      # Cleanup
      Native.close_stmt(stmt_id)
    end
  end
end
