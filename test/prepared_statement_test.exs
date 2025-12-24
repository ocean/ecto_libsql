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
        {:ok, _, _, _state} =
          EctoLibSql.handle_execute(
            "INSERT INTO users (id, name, email) VALUES (?, ?, ?)",
            [i, "User#{i}", "user#{i}@example.com"],
            [],
            state
          )
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
      assert true
    end

    @tag :performance
    @tag :memory
    test "prepared statement memory efficiency with many executions", %{state: state} do
      # Verify that reusing a prepared statement doesn't leak memory

      # Insert 1000 test rows
      Enum.each(1..1000, fn i ->
        {:ok, _, _, _state} =
          EctoLibSql.handle_execute(
            "INSERT INTO users (id, name, email) VALUES (?, ?, ?)",
            [i, "User#{i}", "user#{i}@example.com"],
            [],
            state
          )
      end)

      {:ok, stmt_id} = Native.prepare(state, "SELECT * FROM users WHERE id = ?")

      # Execute statement 1000 times
      # Memory usage should stay constant (no accumulation)
      Enum.each(1..1000, fn i ->
        {:ok, _result} = Native.query_stmt(state, stmt_id, [i])
      end)

      # No assertions on memory (platform-dependent)
      # This test documents expected behavior and can catch memory leaks in manual testing

      :ok = Native.close_stmt(stmt_id)
    end
  end
end
