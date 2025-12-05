defmodule EctoLibSql.StatementCachingBenchmarkTest do
  use ExUnit.Case

  alias EctoLibSql.Native
  alias EctoLibSql.State
  alias EctoLibSql.Query

  defp exec_sql(state, sql, args \\ []) do
    query = %Query{statement: sql}
    Native.query(state, query, args)
  end

  setup do
    db_file = "test_stmt_cache_#{:erlang.unique_integer([:positive])}.db"

    conn_id = Native.connect([database: db_file], :local)
    state = %State{conn_id: conn_id, mode: :local, sync: :disable_sync}

    {:ok, _query, _result, state} =
      exec_sql(state, "CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT)")

    on_exit(fn ->
      Native.close(state.conn_id, :conn_id)
      File.rm(db_file)
    end)

    {:ok, state: state}
  end

  describe "Statement Caching Performance" do
    test "prepared statements avoid re-preparation overhead", %{state: state} do
      # Prepare once
      {:ok, stmt_id} = Native.prepare(state, "INSERT INTO test (value) VALUES (?)")

      # Time 100 executions with caching
      start_time = System.monotonic_time(:microsecond)

      Enum.each(1..100, fn i ->
        {:ok, _} =
          Native.execute_stmt(state, stmt_id, "INSERT INTO test (value) VALUES (?)", [
            "value_#{i}"
          ])
      end)

      cached_time = System.monotonic_time(:microsecond) - start_time

      # Cleanup
      Native.close_stmt(stmt_id)

      # Get final count
      {:ok, _, result, _} = exec_sql(state, "SELECT COUNT(*) FROM test")

      [[count]] = result.rows
      assert count == 100

      # Log for visibility (in microseconds)
      IO.puts("\n✓ Cached prepared statements (100 executions): #{cached_time}µs")
      IO.puts("  Average per execution: #{cached_time / 100}µs")

      # Verify it's reasonable performance (< 100µs per insert on average for cached)
      # Note: This is quite fast since we're not doing disk I/O
      assert cached_time < 100_000, "Cached execution should be fast"
    end

    test "statement reset clears bindings correctly", %{state: state} do
      {:ok, stmt_id} = Native.prepare(state, "INSERT INTO test (value) VALUES (?)")

      # First insert
      {:ok, _} =
        Native.execute_stmt(state, stmt_id, "INSERT INTO test (value) VALUES (?)", [
          "first"
        ])

      # Second insert - should use fresh bindings after reset
      {:ok, _} =
        Native.execute_stmt(state, stmt_id, "INSERT INTO test (value) VALUES (?)", [
          "second"
        ])

      Native.close_stmt(stmt_id)

      # Verify both inserts succeeded with correct values
      {:ok, _, result, _} = exec_sql(state, "SELECT value FROM test ORDER BY id")

      values = result.rows |> Enum.map(&List.first/1)
      assert values == ["first", "second"]
    end

    test "multiple statements can be cached independently", %{state: state} do
      {:ok, insert_stmt} =
        Native.prepare(state, "INSERT INTO test (value) VALUES (?)")

      {:ok, select_stmt} = Native.prepare(state, "SELECT * FROM test WHERE value = ?")

      # Insert using first statement
      {:ok, _} =
        Native.execute_stmt(state, insert_stmt, "INSERT INTO test (value) VALUES (?)", [
          "test_value"
        ])

      # Query using second statement
      {:ok, result} = Native.query_stmt(state, select_stmt, ["test_value"])

      assert result.num_rows == 1
      assert [[_id, "test_value"]] = result.rows

      Native.close_stmt(insert_stmt)
      Native.close_stmt(select_stmt)
    end
  end
end
