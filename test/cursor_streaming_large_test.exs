defmodule EctoLibSql.CursorStreamingLargeTest do
  use ExUnit.Case
  alias EctoLibSql

  # These tests verify that cursors can stream large datasets without
  # loading all data into memory at once. They also test cursor lifecycle
  # and batch size handling.

  setup do
    {:ok, state} = EctoLibSql.connect(database: ":memory:")

    # Create a test table for large data
    {:ok, _, _, state} =
      EctoLibSql.handle_execute(
        """
        CREATE TABLE large_data (
          id INTEGER PRIMARY KEY,
          batch_id INTEGER,
          sequence INTEGER,
          value TEXT,
          data BLOB
        )
        """,
        [],
        [],
        state
      )

    on_exit(fn ->
      EctoLibSql.disconnect([], state)
    end)

    {:ok, state: state}
  end

  describe "cursor streaming with large datasets" do
    test "stream 1000 rows without loading all into memory", %{state: state} do
      # Insert 1000 test rows
      state = insert_rows(state, 1, 1000, 1)

      query = %EctoLibSql.Query{statement: "SELECT * FROM large_data ORDER BY id"}

      # Declare cursor
      {:ok, ^query, cursor, state} =
        EctoLibSql.handle_declare(query, [], [], state)

      # Fetch all rows in batches
      row_count = fetch_all_rows(state, cursor, query, max_rows: 500)
      assert row_count == 1000, "Should fetch exactly 1000 rows"
    end

    test "stream 10K rows with different batch sizes", %{state: state} do
      state = insert_rows(state, 1, 10_000, 1)

      query = %EctoLibSql.Query{statement: "SELECT id, value FROM large_data ORDER BY id"}

      {:ok, ^query, cursor, state} =
        EctoLibSql.handle_declare(query, [], [], state)

      # Fetch with batch size 1000
      row_count = fetch_all_rows(state, cursor, query, max_rows: 1000)
      assert row_count == 10_000, "Should fetch exactly 10K rows"
    end

    test "cursor respects max_rows batch size setting", %{state: state} do
      state = insert_rows(state, 1, 5000, 1)

      query = %EctoLibSql.Query{statement: "SELECT * FROM large_data ORDER BY id"}

      {:ok, ^query, cursor, state} =
        EctoLibSql.handle_declare(query, [], [], state)

      # Track batch sizes
      {:cont, result, state} =
        EctoLibSql.handle_fetch(query, cursor, [max_rows: 100], state)

      # First batch should be at most 100 rows
      assert result.num_rows <= 100, "First batch should respect max_rows=100"

      row_count = result.num_rows + fetch_remaining_rows(state, cursor, query, max_rows: 100)
      assert row_count == 5000
    end

    test "cursor with WHERE clause filters on large dataset", %{state: state} do
      # Insert rows with different batch_ids
      state = insert_rows(state, 1, 5000, 1)
      state = insert_rows(state, 5001, 10000, 2)

      query = %EctoLibSql.Query{
        statement: "SELECT * FROM large_data WHERE batch_id = 2 ORDER BY id"
      }

      {:ok, ^query, cursor, state} =
        EctoLibSql.handle_declare(query, [], [], state)

      row_count = fetch_all_rows(state, cursor, query, max_rows: 500)
      assert row_count == 5000, "Should fetch exactly 5000 filtered rows"
    end

    test "cursor processes rows in order", %{state: state} do
      state = insert_rows(state, 1, 1000, 1)

      query = %EctoLibSql.Query{statement: "SELECT id FROM large_data ORDER BY id"}

      {:ok, ^query, cursor, state} =
        EctoLibSql.handle_declare(query, [], [], state)

      # Collect all IDs and verify they're in order
      ids = fetch_all_ids(state, cursor, query, max_rows: 100)
      expected_ids = Enum.to_list(1..1000)
      assert ids == expected_ids, "Rows should be in order"
    end

    test "cursor with BLOB data handles binary correctly", %{state: state} do
      # Create table with binary data
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          """
          CREATE TABLE binary_test (
            id INTEGER PRIMARY KEY,
            data BLOB
          )
          """,
          [],
          [],
          state
        )

      # Insert 100 rows with 1KB binary data each
      state =
        Enum.reduce(1..100, state, fn i, acc_state ->
          binary_data = <<i::integer-32>> <> :binary.copy(<<0xFF>>, 1020)

          {:ok, _, _, new_state} =
            EctoLibSql.handle_execute(
              "INSERT INTO binary_test (id, data) VALUES (?, ?)",
              [i, binary_data],
              [],
              acc_state
            )

          new_state
        end)

      query = %EctoLibSql.Query{statement: "SELECT id, data FROM binary_test ORDER BY id"}

      {:ok, ^query, cursor, state} =
        EctoLibSql.handle_declare(query, [], [], state)

      # Verify binary data is preserved
      binary_rows = fetch_all_binary_rows(state, cursor, query, max_rows: 25)
      assert length(binary_rows) == 100

      # Check first row's binary data
      [first_id, first_data] = hd(binary_rows)
      assert first_id == 1
      assert is_binary(first_data)
      assert byte_size(first_data) == 1024
    end

    test "cursor with JOIN on large dataset", %{state: state} do
      # Create another table for join
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          """
          CREATE TABLE categories (
            id INTEGER PRIMARY KEY,
            name TEXT
          )
          """,
          [],
          [],
          state
        )

      # Insert categories
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO categories (id, name) VALUES (1, 'cat1'), (2, 'cat2')",
          [],
          [],
          state
        )

      # Insert 5000 rows
      state = insert_rows(state, 1, 5000, 1)

      query = %EctoLibSql.Query{
        statement:
          "SELECT ld.id, ld.value, c.name FROM large_data ld LEFT JOIN categories c ON ld.batch_id = c.id ORDER BY ld.id"
      }

      {:ok, ^query, cursor, state} =
        EctoLibSql.handle_declare(query, [], [], state)

      row_count = fetch_all_rows(state, cursor, query, max_rows: 500)
      assert row_count == 5000
    end

    test "cursor with computed/derived columns", %{state: state} do
      state = insert_rows(state, 1, 1000, 1)

      query = %EctoLibSql.Query{
        statement:
          "SELECT id, value, LENGTH(value) as value_length, batch_id * 10 as scaled_batch FROM large_data ORDER BY id"
      }

      {:ok, ^query, cursor, state} =
        EctoLibSql.handle_declare(query, [], [], state)

      rows = fetch_all_computed_rows(state, cursor, query, max_rows: 100)
      assert length(rows) == 1000

      # Verify computed columns
      [first_id, first_value, first_length, first_scaled] = hd(rows)
      assert first_id == 1
      assert is_binary(first_value)
      assert first_length == String.length(first_value)
      # 1 * 10
      assert first_scaled == 10
    end

    test "cursor lifecycle: declare, fetch in batches, implicit close", %{state: state} do
      state = insert_rows(state, 1, 1000, 1)

      query = %EctoLibSql.Query{statement: "SELECT * FROM large_data ORDER BY id"}

      {:ok, ^query, cursor, state} =
        EctoLibSql.handle_declare(query, [], [], state)

      # Fetch multiple batches
      batch_count = count_batches(state, cursor, query, max_rows: 100)

      # Should have exactly 11 batches: 10 with 100 rows each, plus 1 final batch with 0 rows
      assert batch_count == 11, "Should have exactly 11 batches for 1000 rows with batch size 100"
    end

    test "cursor with aggregation query", %{state: state} do
      state = insert_rows(state, 1, 1000, 1)

      query = %EctoLibSql.Query{statement: "SELECT COUNT(*) as count FROM large_data"}

      {:ok, ^query, cursor, state} =
        EctoLibSql.handle_declare(query, [], [], state)

      {:cont, result, _state} =
        EctoLibSql.handle_fetch(query, cursor, [max_rows: 100], state)

      [[count]] = result.rows
      assert count == 1000
    end

    test "cursor with GROUP BY and aggregation", %{state: state} do
      # Insert rows with different batch_ids
      state =
        Enum.reduce(1..5, state, fn batch, acc_state ->
          insert_rows(acc_state, (batch - 1) * 2000 + 1, batch * 2000, batch)
        end)

      query = %EctoLibSql.Query{
        statement:
          "SELECT batch_id, COUNT(*) as count FROM large_data GROUP BY batch_id ORDER BY batch_id"
      }

      {:ok, ^query, cursor, state} =
        EctoLibSql.handle_declare(query, [], [], state)

      rows = fetch_all_group_rows(state, cursor, query, max_rows: 10)

      # Should have 5 groups
      assert length(rows) == 5

      # Each group should have 2000 rows
      Enum.each(rows, fn [_batch_id, count] ->
        assert count == 2000
      end)
    end

    test "cursor with OFFSET/LIMIT", %{state: state} do
      state = insert_rows(state, 1, 1000, 1)

      query = %EctoLibSql.Query{
        statement: "SELECT id FROM large_data ORDER BY id LIMIT 100 OFFSET 500"
      }

      {:ok, ^query, cursor, state} =
        EctoLibSql.handle_declare(query, [], [], state)

      ids = fetch_all_ids(state, cursor, query, max_rows: 50)

      # Should get rows 501-600
      assert length(ids) == 100
      assert hd(ids) == 501
      assert List.last(ids) == 600
    end

    test "cursor with DISTINCT", %{state: state} do
      # Insert rows with repeating batch_ids (using different ID ranges)
      state = insert_rows(state, 1, 100, 1)
      state = insert_rows(state, 101, 200, 2)
      state = insert_rows(state, 201, 300, 1)
      state = insert_rows(state, 301, 400, 3)
      state = insert_rows(state, 401, 500, 2)
      state = insert_rows(state, 501, 600, 1)

      query = %EctoLibSql.Query{
        statement: "SELECT DISTINCT batch_id FROM large_data ORDER BY batch_id"
      }

      {:ok, ^query, cursor, state} =
        EctoLibSql.handle_declare(query, [], [], state)

      rows = fetch_all_distinct_rows(state, cursor, query, max_rows: 10)

      # Should have 3 distinct batch_ids: 1, 2, 3
      assert length(rows) == 3
      assert List.flatten(rows) == [1, 2, 3]
    end
  end

  # ============================================================================
  # HELPER FUNCTIONS
  # ============================================================================

  defp insert_rows(state, start_id, end_id, batch_id) do
    # Use a prepared statement to reduce overhead per insert
    {:ok, stmt} =
      EctoLibSql.Native.prepare(
        state,
        "INSERT INTO large_data (id, batch_id, sequence, value) VALUES (?, ?, ?, ?)"
      )

    state =
      Enum.reduce(start_id..end_id, state, fn id, acc_state ->
        value = "value_#{id}_batch_#{batch_id}"

        {:ok, _changes} =
          EctoLibSql.Native.execute_stmt(
            acc_state,
            stmt,
            "INSERT INTO large_data (id, batch_id, sequence, value) VALUES (?, ?, ?, ?)",
            [id, batch_id, id - start_id + 1, value]
          )

        acc_state
      end)

    # Clean up prepared statement
    :ok = EctoLibSql.Native.close_stmt(stmt)
    state
  end

  defp fetch_all_rows(state, cursor, query, opts) do
    case EctoLibSql.handle_fetch(query, cursor, opts, state) do
      {:cont, result, next_state} ->
        result.num_rows + fetch_all_rows(next_state, cursor, query, opts)

      {:halt, result, _state} ->
        result.num_rows

      {:error, reason, _state} ->
        flunk("Cursor fetch failed with error: #{inspect(reason)}")
    end
  end

  defp fetch_remaining_rows(state, cursor, query, opts) do
    case EctoLibSql.handle_fetch(query, cursor, opts, state) do
      {:cont, result, next_state} ->
        result.num_rows + fetch_remaining_rows(next_state, cursor, query, opts)

      {:halt, result, _state} ->
        result.num_rows

      {:error, reason, _state} ->
        flunk("Cursor fetch failed with error: #{inspect(reason)}")
    end
  end

  defp fetch_all_ids(state, cursor, query, opts) do
    # Use accumulator to avoid O(n²) list concatenation.
    # Collect batches in reverse order, then flatten with nested reverses for correctness.
    fetch_all_ids_acc(state, cursor, query, opts, [])
    |> Enum.reverse()
    |> List.flatten()
  end

  defp fetch_all_ids_acc(state, cursor, query, opts, acc) do
    case EctoLibSql.handle_fetch(query, cursor, opts, state) do
      {:cont, result, next_state} ->
        ids = Enum.map(result.rows, fn [id] -> id end)
        # Collect batches as nested lists to avoid intermediate reversals
        fetch_all_ids_acc(next_state, cursor, query, opts, [ids | acc])

      {:halt, result, _state} ->
        ids = Enum.map(result.rows, fn [id] -> id end)
        [ids | acc]
    end
  end

  # Generic helper to collect all rows from a cursor by repeatedly fetching batches
  # Uses accumulator to avoid O(n²) list concatenation with ++
  defp fetch_all_cursor_rows(state, cursor, query, opts) do
    fetch_all_cursor_rows_acc(state, cursor, query, opts, [])
    |> Enum.reverse()
  end

  defp fetch_all_cursor_rows_acc(state, cursor, query, opts, acc) do
    case EctoLibSql.handle_fetch(query, cursor, opts, state) do
      {:cont, result, next_state} ->
        # Prepend reversed batch to accumulator to maintain order
        new_acc = Enum.reverse(result.rows) ++ acc
        fetch_all_cursor_rows_acc(next_state, cursor, query, opts, new_acc)

      {:halt, result, _state} ->
        Enum.reverse(result.rows) ++ acc
    end
  end

  # Aliases for backwards compatibility and semantic clarity
  defp fetch_all_binary_rows(state, cursor, query, opts) do
    fetch_all_cursor_rows(state, cursor, query, opts)
  end

  defp fetch_all_computed_rows(state, cursor, query, opts) do
    fetch_all_cursor_rows(state, cursor, query, opts)
  end

  defp fetch_all_group_rows(state, cursor, query, opts) do
    fetch_all_cursor_rows(state, cursor, query, opts)
  end

  defp fetch_all_distinct_rows(state, cursor, query, opts) do
    fetch_all_cursor_rows(state, cursor, query, opts)
  end

  defp count_batches(state, cursor, query, opts) do
    case EctoLibSql.handle_fetch(query, cursor, opts, state) do
      {:cont, _result, next_state} ->
        1 + count_batches(next_state, cursor, query, opts)

      {:halt, _result, _state} ->
        1
    end
  end
end
