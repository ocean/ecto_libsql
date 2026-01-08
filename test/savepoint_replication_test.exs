defmodule EctoLibSql.SavepointReplicationTest do
  @moduledoc """
  Tests for savepoint behavior when used with replication/remote sync.

  Focused on critical integration scenarios:
  1. Savepoints work correctly in replica mode with sync enabled
  2. Savepoint rollback doesn't interfere with remote sync
  3. Error recovery with savepoints in replicated transactions

  These tests require TURSO_DB_URI and TURSO_AUTH_TOKEN for remote testing.
  Tests are skipped if credentials are not provided.
  """
  use ExUnit.Case

  @turso_uri System.get_env("TURSO_DB_URI")
  @turso_token System.get_env("TURSO_AUTH_TOKEN")

  # Skip tests if Turso credentials aren't provided
  @moduletag skip: is_nil(@turso_uri) || is_nil(@turso_token)

  setup do
    unique_id = :erlang.unique_integer([:positive])
    test_db = "z_ecto_libsql_test-savepoint_replication_#{unique_id}.db"
    test_table = "test_users_#{unique_id}"

    {:ok, state} =
      if not (is_nil(@turso_uri) or is_nil(@turso_token)) do
        # Connect with replica mode for replication
        EctoLibSql.connect(
          database: test_db,
          uri: @turso_uri,
          auth_token: @turso_token,
          sync: true
        )
      else
        # Fallback to local (tests will skip)
        EctoLibSql.connect(database: test_db)
      end

    # Create unique test table for this test
    {:ok, _query, _result, state} =
      EctoLibSql.handle_execute(
        "CREATE TABLE #{test_table} (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)",
        [],
        [],
        state
      )

    on_exit(fn ->
      try do
        EctoLibSql.disconnect([], state)
      rescue
        _ -> :ok
      end

      File.rm(test_db)
      File.rm(test_db <> "-shm")
      File.rm(test_db <> "-wal")
    end)

    {:ok, state: state, table: test_table}
  end

  describe "savepoints in replica mode with sync" do
    test "basic savepoint operation works with replica sync enabled", %{state: state, table: table} do
      {:ok, trx_state} = EctoLibSql.Native.begin(state)

      # Create savepoint
      :ok = EctoLibSql.Native.create_savepoint(trx_state, "sp1")

      # Execute within savepoint
      {:ok, _query, _result, trx_state} =
        EctoLibSql.handle_execute(
          "INSERT INTO #{table} (name) VALUES (?)",
          ["Alice"],
          [],
          trx_state
        )

      # Release and commit (which syncs to remote)
      :ok = EctoLibSql.Native.release_savepoint_by_name(trx_state, "sp1")
      {:ok, _state} = EctoLibSql.Native.commit(trx_state)

      # Verify data persisted
      {:ok, _query, result, _state} = EctoLibSql.handle_execute(
        "SELECT COUNT(*) FROM #{table}",
        [],
        [],
        state
      )

      assert [[1]] = result.rows
    end

    test "savepoint rollback with remote sync preserves outer transaction", %{state: state, table: table} do
      {:ok, trx_state} = EctoLibSql.Native.begin(state)

      # Outer transaction: insert Alice
      {:ok, _query, _result, trx_state} =
        EctoLibSql.handle_execute(
          "INSERT INTO #{table} (name) VALUES (?)",
          ["Alice"],
          [],
          trx_state
        )

      # Savepoint: insert Bob and rollback
      :ok = EctoLibSql.Native.create_savepoint(trx_state, "sp1")

      {:ok, _query, _result, trx_state} =
        EctoLibSql.handle_execute(
          "INSERT INTO #{table} (name) VALUES (?)",
          ["Bob"],
          [],
          trx_state
        )

      :ok = EctoLibSql.Native.rollback_to_savepoint_by_name(trx_state, "sp1")

      # Commit (syncs to remote)
      {:ok, _state} = EctoLibSql.Native.commit(trx_state)

      # Only Alice should exist
      {:ok, _query, result, _state} = EctoLibSql.handle_execute(
        "SELECT name FROM #{table} ORDER BY name",
        [],
        [],
        state
      )

      assert result.rows == [["Alice"]]
    end

    test "nested savepoints work correctly with remote sync", %{state: state, table: table} do
      {:ok, trx_state} = EctoLibSql.Native.begin(state)

      # Level 0: Insert Alice
      {:ok, _query, _result, trx_state} =
        EctoLibSql.handle_execute(
          "INSERT INTO #{table} (name) VALUES (?)",
          ["Alice"],
          [],
          trx_state
        )

      # Level 1: Savepoint sp1
      :ok = EctoLibSql.Native.create_savepoint(trx_state, "sp1")

      {:ok, _query, _result, trx_state} =
        EctoLibSql.handle_execute(
          "INSERT INTO #{table} (name) VALUES (?)",
          ["Bob"],
          [],
          trx_state
        )

      # Level 2: Savepoint sp2
      :ok = EctoLibSql.Native.create_savepoint(trx_state, "sp2")

      {:ok, _query, _result, trx_state} =
        EctoLibSql.handle_execute(
          "INSERT INTO #{table} (name) VALUES (?)",
          ["Charlie"],
          [],
          trx_state
        )

      # Rollback sp2 (removes Charlie, keeps Alice and Bob)
      :ok = EctoLibSql.Native.rollback_to_savepoint_by_name(trx_state, "sp2")

      # Commit (syncs to remote)
      {:ok, _state} = EctoLibSql.Native.commit(trx_state)

      # Alice and Bob should exist
      {:ok, _query, result, _state} = EctoLibSql.handle_execute(
        "SELECT COUNT(*) FROM #{table}",
        [],
        [],
        state
      )

      assert [[2]] = result.rows
    end
  end

  describe "savepoint error recovery with remote sync" do
    test "savepoint enables error recovery in replicated transactions", %{state: state, table: table} do
      # Insert a row with specific ID for constraint violation test
      {:ok, _query, _result, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO #{table} (id, name) VALUES (?, ?)",
          [100, "PreExisting"],
          [],
          state
        )

      # Start transaction with savepoint
      {:ok, trx_state} = EctoLibSql.Native.begin(state)

      :ok = EctoLibSql.Native.create_savepoint(trx_state, "sp1")

      # Try to insert duplicate (will fail)
      result =
        EctoLibSql.handle_execute(
          "INSERT INTO #{table} (id, name) VALUES (?, ?)",
          [100, "Duplicate"],
          [],
          trx_state
        )

      assert {:error, _reason, trx_state} = result

      # Rollback savepoint to recover
      :ok = EctoLibSql.Native.rollback_to_savepoint_by_name(trx_state, "sp1")

      # Insert different row
      {:ok, _query, _result, trx_state} =
        EctoLibSql.handle_execute(
          "INSERT INTO #{table} (name) VALUES (?)",
          ["NewRow"],
          [],
          trx_state
        )

      # Commit (syncs to remote)
      {:ok, _state} = EctoLibSql.Native.commit(trx_state)

      # Both original and new should exist
      {:ok, _query, result, _state} = EctoLibSql.handle_execute(
        "SELECT COUNT(*) FROM #{table}",
        [],
        [],
        state
      )

      assert [[2]] = result.rows
    end
  end
end
