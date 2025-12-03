defmodule EctoLibSql.BatchFeaturesTest do
  @moduledoc """
  Tests for batch execution features.

  Includes both implemented (transactional/non-transactional batch) and
  unimplemented (native batch via LibSQL API) features.
  """
  use ExUnit.Case

  setup do
    test_db = "test_batch_#{:erlang.unique_integer([:positive])}.db"

    on_exit(fn ->
      File.rm(test_db)
    end)

    {:ok, database: test_db}
  end

  # ============================================================================
  # Native batch execution (SQL string) - IMPLEMENTED ✅
  # ============================================================================

  describe "native batch execution (SQL string)" do
    test "execute_batch_sql executes multiple statements", %{database: database} do
      {:ok, state} = EctoLibSql.connect(database: database)

      sql = """
      CREATE TABLE batch_test (id INTEGER PRIMARY KEY, name TEXT);
      INSERT INTO batch_test (name) VALUES ('Alice');
      INSERT INTO batch_test (name) VALUES ('Bob');
      SELECT * FROM batch_test ORDER BY id;
      """

      {:ok, results} = EctoLibSql.Native.execute_batch_sql(state, sql)

      # Should have results for all statements
      assert is_list(results)
      assert length(results) >= 1

      EctoLibSql.disconnect([], state)
    end

    test "execute_transactional_batch_sql is atomic", %{database: database} do
      {:ok, state} = EctoLibSql.connect(database: database)

      # First create a table
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE atomic_test (id INTEGER PRIMARY KEY, value INTEGER)",
          [],
          [],
          state
        )

      # Insert initial value
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO atomic_test (id, value) VALUES (1, 100)",
          [],
          [],
          state
        )

      # This should fail (duplicate primary key) and rollback the UPDATE
      sql = """
      UPDATE atomic_test SET value = value - 50 WHERE id = 1;
      INSERT INTO atomic_test (id, value) VALUES (1, 200);
      """

      # Should error due to duplicate key
      assert {:error, _} = EctoLibSql.Native.execute_transactional_batch_sql(state, sql)

      # Verify the UPDATE was rolled back
      {:ok, _, result, _} =
        EctoLibSql.handle_execute(
          "SELECT value FROM atomic_test WHERE id = 1",
          [],
          [],
          state
        )

      # Value should still be 100 (not 50)
      assert result.rows == [[100]]

      EctoLibSql.disconnect([], state)
    end

    test "execute_batch_sql handles empty results", %{database: database} do
      {:ok, state} = EctoLibSql.connect(database: database)

      sql = """
      CREATE TABLE empty_test (id INTEGER);
      DROP TABLE empty_test;
      """

      {:ok, results} = EctoLibSql.Native.execute_batch_sql(state, sql)

      assert is_list(results)

      EctoLibSql.disconnect([], state)
    end
  end
end
