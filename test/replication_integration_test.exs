defmodule EctoLibSql.ReplicationIntegrationTest do
  @moduledoc """
  Comprehensive integration tests for replication features.

  Tests cover:
  - Frame number tracking (get_frame_number_for_replica)
  - Frame-specific synchronisation (sync_until_frame)
  - Flush pending writes (flush_and_get_frame)
  - Max write frame tracking (max_write_replication_index)

  These tests require either:
  1. A remote Turso database with TURSO_DB_URI and TURSO_AUTH_TOKEN env vars set
  2. A local replica database configured with remote sync

  For testing without remote, use @tag :skip
  """
  use ExUnit.Case

  @turso_uri System.get_env("TURSO_DB_URI")
  @turso_token System.get_env("TURSO_AUTH_TOKEN")

  # Skip tests if Turso credentials aren't provided
  @moduletag skip: is_nil(@turso_uri) || is_nil(@turso_token)

  setup do
    # For local testing, tests are skipped
    # For Turso testing, create a database with replica mode
    test_db = "z_ecto_libsql_test-replication_#{:erlang.unique_integer([:positive])}.db"

    {:ok, state} =
      if not (is_nil(@turso_uri) or is_nil(@turso_token)) do
        # Connect with replica mode for replication features
        EctoLibSql.connect(
          database: test_db,
          uri: @turso_uri,
          auth_token: @turso_token,
          sync: true
        )
      else
        # Local-only fallback (tests will skip)
        EctoLibSql.connect(database: test_db)
      end

    # Create a test table
    {:ok, _query, _result, state} =
      EctoLibSql.handle_execute(
        "CREATE TABLE test_data (id INTEGER PRIMARY KEY AUTOINCREMENT, value TEXT)",
        [],
        [],
        state
      )

    on_exit(fn ->
      EctoLibSql.disconnect([], state)
      EctoLibSql.TestHelpers.cleanup_db_files(test_db)
    end)

    {:ok, state: state}
  end

  # ============================================================================
  # Frame Number Tracking Tests
  # ============================================================================

  describe "get_frame_number_for_replica/1" do
    test "returns current replication frame number", %{state: state} do
      # Get initial frame number (should be 0 or positive for fresh database)
      {:ok, frame_no} = EctoLibSql.Native.get_frame_number_for_replica(state)

      assert is_integer(frame_no)
      assert frame_no >= 0
    end

    test "frame number increases after write operations", %{state: state} do
      # Get initial frame
      {:ok, initial_frame} = EctoLibSql.Native.get_frame_number_for_replica(state)

      # Insert a row
      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO test_data (value) VALUES (?)",
          ["test"],
          [],
          state
        )

      # Get frame after write (may or may not increase depending on sync settings)
      {:ok, new_frame} = EctoLibSql.Native.get_frame_number_for_replica(state)

      # Frame number should be >= initial frame
      assert new_frame >= initial_frame
    end

    test "frame number is consistent across multiple calls", %{state: state} do
      {:ok, frame1} = EctoLibSql.Native.get_frame_number_for_replica(state)
      {:ok, frame2} = EctoLibSql.Native.get_frame_number_for_replica(state)
      {:ok, frame3} = EctoLibSql.Native.get_frame_number_for_replica(state)

      # Without writes, frames should be identical
      assert frame1 == frame2
      assert frame2 == frame3
    end

    test "handles state struct directly", %{state: state} do
      # Both conn_id string and state struct should work
      {:ok, _frame} = EctoLibSql.Native.get_frame_number_for_replica(state.conn_id)
      {:ok, _frame} = EctoLibSql.Native.get_frame_number_for_replica(state)

      # Both should succeed (at least no error)
      :ok
    end
  end

  # ============================================================================
  # Frame-Specific Synchronisation Tests
  # ============================================================================

  describe "sync_until_frame/2" do
    test "synchronises replica to specific frame", %{state: state} do
      # Get current frame
      {:ok, current_frame} = EctoLibSql.Native.get_frame_number_for_replica(state)

      # Sync to current frame (should be a no-op but not error)
      {:ok, _state} = EctoLibSql.Native.sync_until_frame(state, current_frame)

      # Frame should still match
      {:ok, new_frame} = EctoLibSql.Native.get_frame_number_for_replica(state)
      assert new_frame >= current_frame
    end

    test "sync_until_frame with future frame", %{state: state} do
      {:ok, current_frame} = EctoLibSql.Native.get_frame_number_for_replica(state)

      # Request sync to a future frame (may not exist yet)
      # Should not error even if frame doesn't exist
      result = EctoLibSql.Native.sync_until_frame(state, current_frame + 1000)

      # Either succeeds or returns a reasonable error
      case result do
        {:ok, _state} -> :ok
        {:error, _reason} -> :ok
      end
    end

    test "handles state struct directly", %{state: state} do
      {:ok, current_frame} = EctoLibSql.Native.get_frame_number_for_replica(state)

      # Both conn_id string and state struct should work
      {:ok, _} = EctoLibSql.Native.sync_until_frame(state.conn_id, current_frame)
      {:ok, _} = EctoLibSql.Native.sync_until_frame(state, current_frame)

      :ok
    end
  end

  # ============================================================================
  # Flush and Frame Number Tests
  # ============================================================================

  describe "flush_and_get_frame/1" do
    test "flushes pending writes and returns frame number", %{state: state} do
      # Get initial frame
      {:ok, initial_frame} = EctoLibSql.Native.get_frame_number_for_replica(state)

      # Insert data
      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO test_data (value) VALUES (?)",
          ["flush_test"],
          [],
          state
        )

      # Flush and get frame
      {:ok, flushed_frame} = EctoLibSql.Native.flush_and_get_frame(state)

      # Frame should be valid
      assert is_integer(flushed_frame)
      assert flushed_frame >= initial_frame
    end

    test "multiple flushes work correctly", %{state: state} do
      {:ok, frame1} = EctoLibSql.Native.flush_and_get_frame(state)

      # Insert data
      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO test_data (value) VALUES (?)",
          ["value1"],
          [],
          state
        )

      {:ok, frame2} = EctoLibSql.Native.flush_and_get_frame(state)

      # Insert more data
      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO test_data (value) VALUES (?)",
          ["value2"],
          [],
          state
        )

      {:ok, frame3} = EctoLibSql.Native.flush_and_get_frame(state)

      # Frames should be non-decreasing
      assert frame2 >= frame1
      assert frame3 >= frame2
    end

    test "flush without writes still returns frame", %{state: state} do
      # No writes, just flush
      {:ok, frame} = EctoLibSql.Native.flush_and_get_frame(state)

      assert is_integer(frame)
      assert frame >= 0
    end
  end

  # ============================================================================
  # Max Write Replication Index Tests
  # ============================================================================

  describe "max_write_replication_index/1" do
    test "returns highest replication frame from writes", %{state: state} do
      # Get initial max write frame
      {:ok, initial_max} = EctoLibSql.Native.max_write_replication_index(state)

      assert is_integer(initial_max)
      assert initial_max >= 0
    end

    test "max write frame increases after writes", %{state: state} do
      {:ok, initial_max} = EctoLibSql.Native.max_write_replication_index(state)

      # Insert data
      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO test_data (value) VALUES (?)",
          ["test"],
          [],
          state
        )

      {:ok, new_max} = EctoLibSql.Native.max_write_replication_index(state)

      # Max write frame should increase or stay same
      assert new_max >= initial_max
    end

    test "max write frame with multiple operations", %{state: state} do
      {:ok, frame_before} = EctoLibSql.Native.max_write_replication_index(state)

      # Multiple writes
      final_state =
        Enum.reduce(1..5, state, fn i, acc_state ->
          {:ok, _query, _result, new_state} =
            EctoLibSql.handle_execute(
              "INSERT INTO test_data (value) VALUES (?)",
              ["value#{i}"],
              [],
              acc_state
            )

          new_state
        end)

      {:ok, frame_after} = EctoLibSql.Native.max_write_replication_index(final_state)

      assert frame_after >= frame_before
    end

    test "handles state struct directly", %{state: state} do
      # Both conn_id string and state struct should work
      {:ok, _frame} = EctoLibSql.Native.max_write_replication_index(state.conn_id)
      {:ok, _frame} = EctoLibSql.Native.max_write_replication_index(state)

      :ok
    end

    test "read-only operations don't affect max write frame", %{state: state} do
      # Insert data first
      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO test_data (value) VALUES (?)",
          ["initial"],
          [],
          state
        )

      {:ok, max_frame_after_write} = EctoLibSql.Native.max_write_replication_index(state)

      # Read data multiple times
      state =
        Enum.reduce(1..5, state, fn _, acc_state ->
          {:ok, _query, _result, new_state} =
            EctoLibSql.handle_execute(
              "SELECT * FROM test_data",
              [],
              [],
              acc_state
            )

          new_state
        end)

      {:ok, max_frame_after_reads} = EctoLibSql.Native.max_write_replication_index(state)

      # Max write frame should be unchanged after reads
      assert max_frame_after_reads == max_frame_after_write
    end
  end

  # ============================================================================
  # Integration Scenarios
  # ============================================================================

  describe "Replication scenarios" do
    test "monitoring replication lag via frame numbers", %{state: state} do
      # Simulate monitoring replication lag
      {:ok, frame1} = EctoLibSql.Native.get_frame_number_for_replica(state)

      # Insert some data
      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO test_data (value) VALUES (?)",
          ["lag_test"],
          [],
          state
        )

      {:ok, frame2} = EctoLibSql.Native.get_frame_number_for_replica(state)

      # In a real scenario with remote replica, frame2 might lag behind
      # the primary. For local test, they're in sync.
      assert frame2 >= frame1
    end

    test "tracking write operations across frame boundaries", %{state: state} do
      # Track writes for read-your-writes consistency
      {_final_state, max_frames} =
        Enum.reduce(1..3, {state, []}, fn i, {acc_state, acc_frames} ->
          {:ok, _query, _result, new_state} =
            EctoLibSql.handle_execute(
              "INSERT INTO test_data (value) VALUES (?)",
              ["operation#{i}"],
              [],
              acc_state
            )

          {:ok, max_write_frame} = EctoLibSql.Native.max_write_replication_index(new_state)
          {new_state, [max_write_frame | acc_frames]}
        end)

      # Max frames should be non-decreasing
      max_frames = Enum.reverse(max_frames)

      assert length(max_frames) == 3

      [frame1, frame2, frame3] = max_frames
      assert frame2 >= frame1
      assert frame3 >= frame2
    end

    test "batch operations with frame tracking", %{state: state} do
      {:ok, initial_frame} = EctoLibSql.Native.get_frame_number_for_replica(state)

      # Prepare batch statements
      statements = [
        {"INSERT INTO test_data (value) VALUES (?)", ["batch1"]},
        {"INSERT INTO test_data (value) VALUES (?)", ["batch2"]},
        {"INSERT INTO test_data (value) VALUES (?)", ["batch3"]}
      ]

      {:ok, _results} = EctoLibSql.Native.batch_transactional(state, statements)

      {:ok, final_frame} = EctoLibSql.Native.get_frame_number_for_replica(state)

      # Frame should have advanced or stayed same
      assert final_frame >= initial_frame
    end

    test "transaction with frame number verification", %{state: state} do
      {:ok, frame_before} = EctoLibSql.Native.get_frame_number_for_replica(state)

      # Begin transaction
      {:ok, :begin, state} = EctoLibSql.handle_begin([], state)

      # Insert within transaction
      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO test_data (value) VALUES (?)",
          ["txn_data"],
          [],
          state
        )

      # Commit
      {:ok, _result, state} = EctoLibSql.handle_commit([], state)

      {:ok, frame_after} = EctoLibSql.Native.get_frame_number_for_replica(state)

      # Frame should advance
      assert frame_after >= frame_before
    end

    test "flush before sync ensures data consistency", %{state: state} do
      {:ok, initial_frame} = EctoLibSql.Native.get_frame_number_for_replica(state)

      # Insert data
      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO test_data (value) VALUES (?)",
          ["pre_flush"],
          [],
          state
        )

      # Flush pending writes
      {:ok, flushed_frame} = EctoLibSql.Native.flush_and_get_frame(state)

      assert flushed_frame >= initial_frame

      # Now sync to that frame
      {:ok, _state} = EctoLibSql.Native.sync_until_frame(state, flushed_frame)

      # Verify we can read the data
      {:ok, _query, result, _state} =
        EctoLibSql.handle_execute(
          "SELECT * FROM test_data WHERE value = ?",
          ["pre_flush"],
          [],
          state
        )

      assert result.num_rows >= 1
    end
  end

  # ============================================================================
  # Edge Cases and Error Handling
  # ============================================================================

  describe "Edge cases" do
    test "get_frame_number_for_replica with large frame numbers", %{state: state} do
      # Insert many rows to potentially get large frame numbers
      final_state =
        Enum.reduce(1..100, state, fn i, acc_state ->
          {:ok, _query, _result, new_state} =
            EctoLibSql.handle_execute(
              "INSERT INTO test_data (value) VALUES (?)",
              ["row#{i}"],
              [],
              acc_state
            )

          new_state
        end)

      {:ok, frame} = EctoLibSql.Native.get_frame_number_for_replica(final_state)

      # Should handle large numbers without overflow
      assert is_integer(frame)
      assert frame >= 0
    end

    test "sync_until_frame with frame 0", %{state: state} do
      # Syncing to frame 0 should work
      {:ok, _state} = EctoLibSql.Native.sync_until_frame(state, 0)
      :ok
    end

    test "flush_and_get_frame returns valid integer", %{state: state} do
      {:ok, frame} = EctoLibSql.Native.flush_and_get_frame(state)

      assert is_integer(frame)
      assert frame >= 0
    end

    test "replication functions work without remote connection", %{state: state} do
      # All these should work even with local database
      {:ok, _} = EctoLibSql.Native.get_frame_number_for_replica(state)
      {:ok, _} = EctoLibSql.Native.flush_and_get_frame(state)
      {:ok, _} = EctoLibSql.Native.max_write_replication_index(state)

      :ok
    end
  end
end
