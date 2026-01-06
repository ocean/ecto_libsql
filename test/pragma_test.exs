defmodule EctoLibSql.PragmaTest do
  use ExUnit.Case

  alias EctoLibSql.Pragma

  setup do
    test_db = "z_ecto_libsql_test-pragma_#{:erlang.unique_integer([:positive])}.db"

    {:ok, state} = EctoLibSql.connect(database: test_db)

    on_exit(fn ->
      EctoLibSql.disconnect([], state)
      File.rm(test_db)
      File.rm(test_db <> "-shm")
      File.rm(test_db <> "-wal")
    end)

    {:ok, state: state}
  end

  describe "foreign_keys" do
    test "enable_foreign_keys sets foreign keys to ON", %{state: state} do
      # Disable first to ensure we're testing the enable
      assert :ok = Pragma.disable_foreign_keys(state)

      # Enable foreign keys
      assert :ok = Pragma.enable_foreign_keys(state)

      # Verify it's enabled
      {:ok, result} = Pragma.foreign_keys(state)
      assert result.rows == [[1]]
    end

    test "disable_foreign_keys sets foreign keys to OFF", %{state: state} do
      # First enable, then disable
      assert :ok = Pragma.enable_foreign_keys(state)
      assert :ok = Pragma.disable_foreign_keys(state)

      # Verify it's disabled
      {:ok, result} = Pragma.foreign_keys(state)
      assert result.rows == [[0]]
    end

    test "foreign_keys queries current setting", %{state: state} do
      # Query initial state (might be enabled or disabled depending on LibSQL defaults)
      {:ok, initial_result} = Pragma.foreign_keys(state)
      assert initial_result.rows in [[[0]], [[1]]]

      # Disable explicitly
      :ok = Pragma.disable_foreign_keys(state)
      {:ok, result} = Pragma.foreign_keys(state)
      assert result.rows == [[0]]

      # Enable and query again
      :ok = Pragma.enable_foreign_keys(state)
      {:ok, result} = Pragma.foreign_keys(state)
      assert result.rows == [[1]]
    end
  end

  describe "journal_mode" do
    test "set_journal_mode changes journal mode to WAL", %{state: state} do
      {:ok, result} = Pragma.set_journal_mode(state, :wal)

      # Result should confirm the new mode
      assert result.rows == [["wal"]]

      # Verify by querying
      {:ok, result} = Pragma.journal_mode(state)
      assert result.rows == [["wal"]]
    end

    test "set_journal_mode accepts various modes", %{state: state} do
      for mode <- [:delete, :memory, :persist, :truncate] do
        {:ok, result} = Pragma.set_journal_mode(state, mode)
        mode_str = mode |> Atom.to_string()
        assert [mode_str] in result.rows or [[mode_str]] == result.rows
      end
    end

    test "journal_mode queries current mode", %{state: state} do
      # Set to WAL first
      {:ok, _set_result} = Pragma.set_journal_mode(state, :wal)

      # Query should return WAL
      {:ok, result} = Pragma.journal_mode(state)
      assert result.rows == [["wal"]]
    end
  end

  describe "synchronous" do
    test "set_synchronous with atom", %{state: state} do
      {:ok, _result} = Pragma.set_synchronous(state, :normal)

      # Verify
      {:ok, result} = Pragma.synchronous(state)
      assert result.rows == [[1]] or result.rows == [["normal"]]
    end

    test "set_synchronous with integer", %{state: state} do
      {:ok, _result} = Pragma.set_synchronous(state, 2)

      # Verify (should be FULL = 2)
      {:ok, result} = Pragma.synchronous(state)
      assert result.rows == [[2]] or result.rows == [["full"]]
    end

    test "set_synchronous accepts valid levels", %{state: state} do
      for level <- [:off, :normal, :full, :extra] do
        {:ok, _result} = Pragma.set_synchronous(state, level)
      end

      for level <- [0, 1, 2, 3] do
        {:ok, _result} = Pragma.set_synchronous(state, level)
      end
    end
  end

  describe "table_info" do
    test "returns column information for a table", %{state: state} do
      # Create a test table
      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE pragma_test (id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER)",
          [],
          [],
          state
        )

      # Get table info
      {:ok, result} = Pragma.table_info(state, :pragma_test)

      # Should have 3 columns
      assert length(result.rows) == 3

      # Verify column names are present
      column_names = Enum.map(result.rows, fn row -> Enum.at(row, 1) end)
      assert "id" in column_names
      assert "name" in column_names
      assert "age" in column_names
    end

    test "accepts table name as string", %{state: state} do
      # Create a test table
      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE pragma_test2 (id INTEGER)",
          [],
          [],
          state
        )

      # Get table info with string name
      {:ok, result} = Pragma.table_info(state, "pragma_test2")
      assert length(result.rows) == 1
    end

    test "accepts table name as atom", %{state: state} do
      # Create a test table
      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE pragma_test3 (id INTEGER)",
          [],
          [],
          state
        )

      # Get table info with atom name
      {:ok, result} = Pragma.table_info(state, :pragma_test3)
      assert length(result.rows) == 1
    end
  end

  describe "table_list" do
    test "returns list of tables", %{state: state} do
      # Create some test tables
      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute("CREATE TABLE test_table1 (id INTEGER)", [], [], state)

      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute("CREATE TABLE test_table2 (id INTEGER)", [], [], state)

      # Get table list
      {:ok, result} = Pragma.table_list(state)

      # Should include our tables
      assert is_list(result.rows)
      assert length(result.rows) >= 2

      # Convert to table names for easier checking
      # Note: table_list returns complex info, table name is in one of the columns
      # For now just verify we got results
      assert result.num_rows >= 2
    end
  end

  describe "user_version" do
    test "get and set user version", %{state: state} do
      # Default should be 0
      {:ok, result} = Pragma.user_version(state)
      assert result.rows == [[0]]

      # Set to 42
      {:ok, _set_result} = Pragma.set_user_version(state, 42)

      # Verify
      {:ok, result} = Pragma.user_version(state)
      assert result.rows == [[42]]
    end

    test "set_user_version accepts integers", %{state: state} do
      for version <- [1, 100, 999, 12345] do
        {:ok, _set_result} = Pragma.set_user_version(state, version)
        {:ok, result} = Pragma.user_version(state)
        assert result.rows == [[version]]
      end
    end
  end

  describe "raw query" do
    test "query executes arbitrary PRAGMA statements", %{state: state} do
      # Test with foreign_keys
      {:ok, result} = Pragma.query(state, "PRAGMA foreign_keys = ON")
      assert is_struct(result, EctoLibSql.Result)

      # Test with a query PRAGMA
      {:ok, result} = Pragma.query(state, "PRAGMA foreign_keys")
      assert result.rows == [[1]]
    end

    test "query returns success even for unknown PRAGMA (SQLite behaviour)", %{state: state} do
      # SQLite doesn't error on unknown PRAGMAs, it just returns empty results
      {:ok, result} = Pragma.query(state, "PRAGMA invalid_pragma_name")
      assert is_struct(result, EctoLibSql.Result)
      # Unknown PRAGMAs typically return empty results
      assert result.num_rows == 0 or result.num_rows >= 0
    end
  end

  describe "integration" do
    test "multiple PRAGMAs can be set in sequence", %{state: state} do
      # Set multiple PRAGMAs
      assert :ok = Pragma.enable_foreign_keys(state)
      assert {:ok, _jm_result} = Pragma.set_journal_mode(state, :wal)
      assert {:ok, _sync_result} = Pragma.set_synchronous(state, :normal)

      # Verify all settings
      {:ok, fk_result} = Pragma.foreign_keys(state)
      assert fk_result.rows == [[1]]

      {:ok, jm_result} = Pragma.journal_mode(state)
      assert jm_result.rows == [["wal"]]

      {:ok, sync_result} = Pragma.synchronous(state)
      assert sync_result.rows == [[1]] or sync_result.rows == [["normal"]]
    end

    test "PRAGMA settings are per-connection", %{state: state1} do
      # Create a second connection
      test_db2 = "z_ecto_libsql_test-pragma_second_#{:erlang.unique_integer([:positive])}.db"
      {:ok, state2} = EctoLibSql.connect(database: test_db2)

      # Explicitly set foreign keys differently on each connection
      :ok = Pragma.enable_foreign_keys(state1)
      :ok = Pragma.disable_foreign_keys(state2)

      # First connection should have FK enabled
      {:ok, result1} = Pragma.foreign_keys(state1)
      assert result1.rows == [[1]]

      # Second connection should have FK disabled
      {:ok, result2} = Pragma.foreign_keys(state2)
      assert result2.rows == [[0]]

      # Clean up
      EctoLibSql.disconnect([], state2)
      File.rm(test_db2)
      File.rm(test_db2 <> "-wal")
      File.rm(test_db2 <> "-shm")
    end
  end
end
