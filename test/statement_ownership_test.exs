defmodule EctoLibSql.StatementOwnershipTest do
  use ExUnit.Case

  alias EctoLibSql.Native
  alias EctoLibSql.State

  setup do
    db_file1 = "z_ecto_libsql_test-stmt_own_#{:erlang.unique_integer([:positive])}_1.db"
    db_file2 = "z_ecto_libsql_test-stmt_own_#{:erlang.unique_integer([:positive])}_2.db"

    conn_id1 = Native.connect([database: db_file1], :local)
    conn_id2 = Native.connect([database: db_file2], :local)

    true = is_binary(conn_id1) and byte_size(conn_id1) > 0
    true = is_binary(conn_id2) and byte_size(conn_id2) > 0

    state1 = %State{conn_id: conn_id1, mode: :local, sync: :disable_sync}
    state2 = %State{conn_id: conn_id2, mode: :local, sync: :disable_sync}

    on_exit(fn ->
      Native.close(conn_id1, :conn_id)
      Native.close(conn_id2, :conn_id)
      File.rm(db_file1)
      File.rm(db_file1 <> "-shm")
      File.rm(db_file1 <> "-wal")
      File.rm(db_file2)
      File.rm(db_file2 <> "-shm")
      File.rm(db_file2 <> "-wal")
    end)

    {:ok, state1: state1, state2: state2, conn_id1: conn_id1, conn_id2: conn_id2}
  end

  describe "Statement connection ownership validation" do
    test "statement_parameter_count rejects access from wrong connection", %{
      state1: state1,
      conn_id2: conn_id2
    } do
      # Prepare statement on connection 1
      {:ok, stmt_id} = Native.prepare(state1, "SELECT ? as val")

      # Try to access from connection 2 - should fail
      result = Native.statement_parameter_count(conn_id2, stmt_id)
      assert result == {:error, "Statement does not belong to connection"}

      Native.close_stmt(stmt_id)
    end

    test "statement_column_count rejects access from wrong connection", %{
      state1: state1,
      conn_id2: conn_id2
    } do
      # Prepare statement on connection 1
      {:ok, stmt_id} = Native.prepare(state1, "SELECT 1 as id, 2 as val")

      # Try to access from connection 2 - should fail
      result = Native.statement_column_count(conn_id2, stmt_id)
      assert result == {:error, "Statement does not belong to connection"}

      Native.close_stmt(stmt_id)
    end

    test "statement_column_name rejects access from wrong connection", %{
      state1: state1,
      conn_id2: conn_id2
    } do
      # Prepare statement on connection 1
      {:ok, stmt_id} = Native.prepare(state1, "SELECT 1 as id, 2 as val")

      # Try to access from connection 2 - should fail
      result = Native.statement_column_name(conn_id2, stmt_id, 0)
      assert result == {:error, "Statement does not belong to connection"}

      Native.close_stmt(stmt_id)
    end

    test "statement introspection works with correct connection", %{
      state1: state1,
      conn_id1: conn_id1
    } do
      # Prepare statement on connection 1
      {:ok, stmt_id} = Native.prepare(state1, "SELECT ? as id, ? as val")

      # Access from same connection should work
      assert 2 = Native.statement_parameter_count(conn_id1, stmt_id)
      assert 2 = Native.statement_column_count(conn_id1, stmt_id)
      assert "id" = Native.statement_column_name(conn_id1, stmt_id, 0)
      assert "val" = Native.statement_column_name(conn_id1, stmt_id, 1)

      Native.close_stmt(stmt_id)
    end
  end

  describe "Transaction connection ownership validation" do
    test "execute_with_transaction rejects access from wrong connection", %{
      state1: state1,
      conn_id2: conn_id2
    } do
      # Create a table in connection 1 and begin transaction
      {:ok, _query, _result, state1} =
        Native.query(
          state1,
          %EctoLibSql.Query{
            statement: "CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT)"
          },
          []
        )

      {:ok, trx_state} = Native.begin(state1)
      trx_id = trx_state.trx_id

      # Try to execute in transaction from connection 2 - should fail
      result =
        Native.execute_with_transaction(trx_id, conn_id2, "INSERT INTO test (value) VALUES (?)", [
          "test"
        ])

      assert {:error, msg} = result
      assert msg =~ "does not belong to this connection"

      # Clean up - use correct connection
      Native.rollback(trx_state)
    end

    test "query_with_trx_args rejects access from wrong connection", %{
      state1: state1,
      conn_id2: conn_id2
    } do
      # Create a table in connection 1 and begin transaction
      {:ok, _query, _result, _state} =
        Native.query(
          state1,
          %EctoLibSql.Query{
            statement: "CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT)"
          },
          []
        )

      {:ok, trx_state} = Native.begin(state1)
      trx_id = trx_state.trx_id

      # Try to query in transaction from connection 2 - should fail
      result = Native.query_with_trx_args(trx_id, conn_id2, "SELECT * FROM test", [])
      assert {:error, msg} = result
      assert msg =~ "does not belong to this connection"

      # Clean up - use correct connection
      Native.rollback(trx_state)
    end

    test "transaction operations work with correct connection", %{
      state1: state1,
      conn_id1: conn_id1
    } do
      # Create a table in connection 1
      {:ok, _query, _result, state1} =
        Native.query(
          state1,
          %EctoLibSql.Query{
            statement: "CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT)"
          },
          []
        )

      # Begin transaction and verify operations work with same connection
      {:ok, trx_state} = Native.begin(state1)
      trx_id = trx_state.trx_id

      # Execute in transaction with correct connection
      num_rows =
        Native.execute_with_transaction(trx_id, conn_id1, "INSERT INTO test (value) VALUES (?)", [
          "value1"
        ])

      assert is_integer(num_rows) and num_rows >= 0

      # Query in transaction with correct connection
      result = Native.query_with_trx_args(trx_id, conn_id1, "SELECT * FROM test", [])

      assert %{
               "columns" => ["id", "value"],
               "rows" => [[_id, "value1"]],
               "num_rows" => 1
             } = result

      # Commit transaction
      Native.commit(trx_state)
    end
  end

  describe "Cursor connection ownership validation" do
    test "fetch_cursor rejects access from wrong connection", %{
      state1: state1,
      conn_id2: conn_id2
    } do
      # Create a table and data in connection 1
      {:ok, _query, _result, state1} =
        Native.query(
          state1,
          %EctoLibSql.Query{
            statement: "CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT)"
          },
          []
        )

      {:ok, _query, _result, state1} =
        Native.query(
          state1,
          %EctoLibSql.Query{
            statement: "INSERT INTO test (value) VALUES (?)"
          },
          ["test_value"]
        )

      # Declare cursor on connection 1
      cursor_id =
        Native.declare_cursor_with_context(
          state1.conn_id,
          state1.conn_id,
          :connection,
          "SELECT * FROM test",
          []
        )

      true = is_binary(cursor_id) and byte_size(cursor_id) > 0

      on_exit(fn ->
        Native.close(cursor_id, :cursor_id)
      end)

      # Try to fetch from cursor using connection 2 - should fail
      result = Native.fetch_cursor(conn_id2, cursor_id, 100)
      assert {:error, msg} = result
      assert msg =~ "does not belong to connection"
    end

    test "fetch_cursor works with correct connection", %{
      state1: state1,
      conn_id1: conn_id1
    } do
      # Create a table and data in connection 1
      {:ok, _query, _result, state1} =
        Native.query(
          state1,
          %EctoLibSql.Query{
            statement: "CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT)"
          },
          []
        )

      {:ok, _query, _result, _state1} =
        Native.query(
          state1,
          %EctoLibSql.Query{
            statement: "INSERT INTO test (value) VALUES (?)"
          },
          ["test_value"]
        )

      # Declare cursor on connection 1
      cursor_id =
        Native.declare_cursor_with_context(
          conn_id1,
          conn_id1,
          :connection,
          "SELECT * FROM test",
          []
        )

      true = is_binary(cursor_id) and byte_size(cursor_id) > 0

      on_exit(fn ->
        Native.close(cursor_id, :cursor_id)
      end)

      # Fetch from cursor using correct connection - should work
      result = Native.fetch_cursor(conn_id1, cursor_id, 100)
      assert {columns, rows, count} = result
      assert columns == ["id", "value"]
      assert rows != []
      assert count >= 0
    end

    test "declare_cursor_with_context rejects transaction from wrong connection", %{
      state1: state1,
      state2: state2,
      conn_id1: conn_id1,
      conn_id2: conn_id2
    } do
      # Create table on both connections
      {:ok, _, _, _state1} =
        EctoLibSql.handle_execute(
          %EctoLibSql.Query{
            statement: "CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT)"
          },
          [],
          [],
          state1
        )

      {:ok, _, _, _state2} =
        EctoLibSql.handle_execute(
          %EctoLibSql.Query{
            statement: "CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT)"
          },
          [],
          [],
          state2
        )

      # Start transaction on connection 1
      trx_id = Native.begin_transaction(conn_id1)
      true = is_binary(trx_id) and byte_size(trx_id) > 0

      on_exit(fn ->
        Native.commit_or_rollback_transaction(trx_id, conn_id1, :local, :disable_sync, "rollback")
      end)

      # Try to declare cursor on transaction 1 using connection 2 - should fail
      result =
        Native.declare_cursor_with_context(
          conn_id2,
          trx_id,
          :transaction,
          "SELECT * FROM test",
          []
        )

      assert {:error, msg} = result
      assert msg =~ "does not belong to this connection"

      # Verify transaction still works with correct connection
      result2 =
        Native.declare_cursor_with_context(
          conn_id1,
          trx_id,
          :transaction,
          "SELECT * FROM test",
          []
        )

      assert is_binary(result2)

      # Clean up cursor from successful declaration
      Native.close(result2, :cursor_id)
    end

    test "declare_cursor_with_context validates connection ID matches for connection type", %{
      state1: state1,
      conn_id1: conn_id1,
      conn_id2: conn_id2
    } do
      # Create table
      {:ok, _, _, _state1} =
        EctoLibSql.handle_execute(
          %EctoLibSql.Query{
            statement: "CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT)"
          },
          [],
          [],
          state1
        )

      # Try to declare cursor with mismatched conn_id and id - should fail
      result =
        Native.declare_cursor_with_context(
          conn_id2,
          conn_id1,
          :connection,
          "SELECT * FROM test",
          []
        )

      assert {:error, msg} = result
      assert msg =~ "Connection ID mismatch"

      # Verify it works with matching IDs
      result2 =
        Native.declare_cursor_with_context(
          conn_id1,
          conn_id1,
          :connection,
          "SELECT * FROM test",
          []
        )

      assert is_binary(result2)

      on_exit(fn ->
        Native.close(result2, :cursor_id)
      end)
    end
  end
end
