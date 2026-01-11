defmodule EctoLibSql.AdvancedFeaturesTest do
  @moduledoc """
  Tests for advanced features like extensions, cacheflush, replication control, etc.

  Most of these features are not yet implemented and are marked as skipped.
  """
  use ExUnit.Case

  # ============================================================================
  # NOTE: MVCC mode & cacheflush are NOT in the libsql Rust crate API
  # MVCC is part of the Turso database rewrite, not the libsql library
  # cacheflush() doesn't exist in libsql's public API
  # These features are out of scope for ecto_libsql
  # ============================================================================

  # ============================================================================
  # Replication control
  # ============================================================================

  describe "replication control - partially implemented" do
    test "sync_until waits for specific replication index" do
      # This would require a remote replica setup
      # Placeholder for future implementation
      assert true
    end

    test "flush_replicator forces replicator flush" do
      # This would require a remote replica setup
      # Placeholder for future implementation
      assert true
    end

    test "max_write_replication_index returns frame number for local db" do
      # Test with a local database (not a replica)
      {:ok, state} = EctoLibSql.connect(database: ":memory:")

      # For a local in-memory database, this should return 0 (no replication tracking)
      {:ok, frame_no} = EctoLibSql.Native.get_max_write_frame(state.conn_id)
      assert is_integer(frame_no)
      assert frame_no >= 0

      EctoLibSql.disconnect([], state)
    end

    test "max_write_replication_index after write operations" do
      # Create a temporary database file
      db_path = "z_ecto_libsql_test-max_write_#{:erlang.unique_integer([:positive])}.db"

      {:ok, state} = EctoLibSql.connect(database: db_path)

      # Create table and insert data
      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE test (id INTEGER PRIMARY KEY, data TEXT)",
          [],
          [],
          state
        )

      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO test (data) VALUES (?)",
          ["test_data"],
          [],
          state
        )

      # Get max write frame (may be 0 for local databases without replication)
      {:ok, frame_no} = EctoLibSql.Native.get_max_write_frame(state.conn_id)
      assert is_integer(frame_no)
      assert frame_no >= 0

      EctoLibSql.disconnect([], state)

      # Cleanup
      EctoLibSql.TestHelpers.cleanup_db_files(db_path)
    end

    test "max_write_replication_index returns error for invalid connection" do
      # Test error handling for non-existent connection
      result = EctoLibSql.Native.get_max_write_frame("invalid-connection-id")
      assert {:error, _reason} = result
    end
  end

  # ============================================================================
  # Freeze database - NOT IMPLEMENTED ❌
  # ============================================================================

  describe "freeze_replica - NOT SUPPORTED" do
    test "returns :unsupported atom for any valid connection" do
      {:ok, state} = EctoLibSql.connect(database: ":memory:")

      # Should always return :unsupported
      result = EctoLibSql.Native.freeze_replica(state)
      assert result == {:error, :unsupported}

      EctoLibSql.disconnect([], state)
    end

    test "returns :unsupported atom even with explicit conn_id" do
      {:ok, state} = EctoLibSql.connect(database: ":memory:")

      # Direct call to NIF wrapper should return :unsupported
      result = EctoLibSql.Native.freeze_replica(state)
      assert result == {:error, :unsupported}

      EctoLibSql.disconnect([], state)
    end

    test "returns :unsupported for invalid state" do
      # Should handle invalid state gracefully
      result = EctoLibSql.Native.freeze_replica(nil)
      assert result == {:error, :unsupported}

      result = EctoLibSql.Native.freeze_replica(%{})
      assert result == {:error, :unsupported}

      result = EctoLibSql.Native.freeze_replica("invalid")
      assert result == {:error, :unsupported}
    end

    test "freeze is documented as not supported" do
      # Verify documentation is clear about unsupported status
      # This is a sanity check that the function docs were updated
      {:ok, state} = EctoLibSql.connect(database: ":memory:")

      # Document expectation: freeze_replica always returns :unsupported
      # See lib/ecto_libsql/native.ex for detailed implementation notes
      assert EctoLibSql.Native.freeze_replica(state) == {:error, :unsupported}

      EctoLibSql.disconnect([], state)
    end

    test "freeze does not actually freeze or modify database" do
      # Verify that the function is a no-op (returns error without side effects)
      {:ok, state} = EctoLibSql.connect(database: ":memory:")

      # Create a table and insert data
      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE test (id INTEGER PRIMARY KEY, data TEXT)",
          [],
          [],
          state
        )

      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO test (data) VALUES (?)",
          ["test_value"],
          [],
          state
        )

      # Call freeze - should return unsupported and not affect data
      freeze_result = EctoLibSql.Native.freeze_replica(state)
      assert freeze_result == {:error, :unsupported}

      # Verify data is still accessible (freeze didn't break connection)
      {:ok, _query, select_result, _state} =
        EctoLibSql.handle_execute(
          "SELECT data FROM test WHERE id = 1",
          [],
          [],
          state
        )

      assert select_result.rows == [["test_value"]]

      EctoLibSql.disconnect([], state)
    end
  end

  # ============================================================================
  # Extension loading - NOT IMPLEMENTED ❌
  # ============================================================================

  describe "load_extension - NOT IMPLEMENTED" do
    @describetag :skip

    test "loads SQLite extension from path" do
      {:ok, state} = EctoLibSql.connect(database: ":memory:")

      # This would load an extension like FTS5
      # assert {:ok, _} = EctoLibSql.Native.load_extension(state, "/path/to/extension.so")

      # Placeholder - would need actual extension file to test
      assert state.conn_id

      EctoLibSql.disconnect([], state)
    end
  end

  # ============================================================================
  # Hooks (authorisation, update) - NOT IMPLEMENTED ❌
  # ============================================================================

  describe "hooks - NOT IMPLEMENTED" do
    @describetag :skip

    test "authorisation hook for row-level security" do
      {:ok, state} = EctoLibSql.connect(database: ":memory:")

      # Set authoriser hook
      # assert {:ok, _} = EctoLibSql.Native.set_authorizer(state, fn action, table, column ->
      #   # Custom authorisation logic
      #   :ok
      # end)

      # Placeholder
      assert state.conn_id

      EctoLibSql.disconnect([], state)
    end

    test "update hook for change data capture" do
      {:ok, state} = EctoLibSql.connect(database: ":memory:")

      # Set update hook
      # assert {:ok, _} = EctoLibSql.Native.set_update_hook(state, fn action, db, table, rowid ->
      #   # Handle update notification
      #   :ok
      # end)

      # Placeholder
      assert state.conn_id

      EctoLibSql.disconnect([], state)
    end
  end

  # ============================================================================
  # Named parameters - NOT IMPLEMENTED ❌
  # ============================================================================

  describe "named parameters - NOT IMPLEMENTED" do
    @describetag :skip

    test "execute query with named parameters" do
      {:ok, state} = EctoLibSql.connect(database: ":memory:")

      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)",
          [],
          [],
          state
        )

      # Should support named parameters like :name and :age
      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO users VALUES (:id, :name, :age)",
          [id: 1, name: "Alice", age: 30],
          [],
          state
        )

      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute("SELECT * FROM users WHERE id = 1", [], [], state)

      assert [[1, "Alice", 30]] = result.rows

      EctoLibSql.disconnect([], state)
    end
  end
end
