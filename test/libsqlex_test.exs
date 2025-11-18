defmodule LibSqlExTest do
  use ExUnit.Case
  doctest LibSqlEx

  setup_all do
    # Clean up any existing test database from previous runs
    File.rm("bar.db")

    :ok
  end

  setup do
    # Create a unique database file for each test to ensure isolation
    test_db = "test_#{:erlang.unique_integer([:positive])}.db"

    opts = [
      uri: System.get_env("LIBSQL_URI"),
      auth_token: System.get_env("LIBSQL_TOKEN"),
      database: test_db,
      # sync is optional
      sync: true
    ]

    # Clean up database file after test completes
    on_exit(fn ->
      File.rm(test_db)
    end)

    {:ok, opts: opts}
  end

  test "connection remote replica", state do
    assert {:ok, _} = LibSqlEx.connect(state[:opts])
  end

  test "ping connection", state do
    {:ok, conn} = LibSqlEx.connect(state[:opts])
    assert {:ok, _} = LibSqlEx.ping(conn)
  end

  test "prepare and execute a simple select", state do
    {:ok, state} = LibSqlEx.connect(state[:opts])

    query = %LibSqlEx.Query{statement: "SELECT 1 + 1"}
    res_execute = LibSqlEx.handle_execute(query, [], [], state)
    assert {:ok, _, _, _} = res_execute
  end

  test "create table", state do
    {:ok, state} = LibSqlEx.connect(state[:opts])

    query = %LibSqlEx.Query{
      statement:
        "CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, email TEXT)"
    }

    assert {:ok, _, _, _} = LibSqlEx.handle_execute(query, [], [], state)
  end

  test "transaction and param", state do
    {:ok, state} = LibSqlEx.connect(state[:opts])

    # trx_id here
    {:ok, _, new_state} = LibSqlEx.handle_begin([], state)

    query = %LibSqlEx.Query{statement: "INSERT INTO users (name, email) values (?1, ?2)"}
    param = ["foo", "bar@mail.com"]

    _exec =
      LibSqlEx.handle_execute(
        query,
        param,
        [],
        new_state
      )

    commit = LibSqlEx.handle_commit([], new_state)
    # handle_commit return :ok, result, and new_state
    assert {:ok, _, _} = commit
  end

  # passed
  test "vector", state do
    query = "CREATE TABLE IF NOT EXISTS movies ( title TEXT, year INT, embedding F32_BLOB(3)
);"
    {:ok, conn} = LibSqlEx.connect(state[:opts])

    LibSqlEx.handle_execute(%LibSqlEx.Query{statement: query}, [], [], conn)

    insert =
      " INSERT INTO movies (title, year, embedding) VALUES ('Napoleon', 2023, vector('[1,2,3]')), ('Black Hawk Down', 2001, vector('[10,11,12]')), ('Gladiator', 2000, vector('[7,8,9]')), ('Blade Runner', 1982, vector('[4,5,6]'));"

    LibSqlEx.handle_execute(%LibSqlEx.Query{statement: insert}, [], [], conn)

    select =
      "SELECT * FROM movies WHERE year >= 2020 ORDER BY vector_distance_cos(embedding, '[3,1,2]') LIMIT 3;"

    res_query = LibSqlEx.handle_execute(%LibSqlEx.Query{statement: select}, [], [], conn)

    assert {:ok, _, _, _} = res_query
  end

  test "disconnect", state do
    opts = state[:opts]
    {:ok, conn} = LibSqlEx.connect(opts)

    dis = LibSqlEx.disconnect([], conn)
    assert :ok == dis
  end

  test "handle invalid SQL statement", state do
    {:ok, state} = LibSqlEx.connect(state[:opts])

    query = %LibSqlEx.Query{statement: "SELECT * FROM not_existing_table"}

    assert {:error, %LibSqlEx.Error{}, _} = LibSqlEx.handle_execute(query, [], [], state)
  end

  test "insert and update user", state do
    {:ok, state} = LibSqlEx.connect(state[:opts])

    # Create table first
    create_table = %LibSqlEx.Query{
      statement:
        "CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, email TEXT)"
    }

    {:ok, _, _, state} = LibSqlEx.handle_execute(create_table, [], [], state)

    insert_query = %LibSqlEx.Query{
      statement: "INSERT INTO users (name, email) VALUES (?1, ?2)"
    }

    assert {:ok, _, _, new_state} =
             LibSqlEx.handle_execute(insert_query, ["Alice", "alice@mail.com"], [], state)

    update_query = %LibSqlEx.Query{
      statement: "UPDATE users SET email = ?1 WHERE name = ?2"
    }

    assert {:ok, _, _, final_state} =
             LibSqlEx.handle_execute(update_query, ["alice@new.com", "Alice"], [], new_state)

    select_query = %LibSqlEx.Query{
      statement: "SELECT email FROM users WHERE name = ?1"
    }

    assert {:ok, _, result, _} = LibSqlEx.handle_execute(select_query, ["Alice"], [], final_state)

    assert result.rows == [["alice@new.com"]]
  end

  # libSQL supports multiple statements in one execution
  test "multiple statements in one execution", state do
    {:ok, state} = LibSqlEx.connect(state[:opts])

    # Create table first
    create_table = %LibSqlEx.Query{
      statement:
        "CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, email TEXT)"
    }

    {:ok, _, _, state} = LibSqlEx.handle_execute(create_table, [], [], state)

    query = %LibSqlEx.Query{
      statement: """
      INSERT INTO users (name, email) VALUES ('multi', 'multi@mail.com');
      SELECT * FROM users WHERE name = 'multi';
      """
    }

    # libSQL now supports multiple statements, so this should succeed
    assert {:ok, _, _, _} = LibSqlEx.handle_execute(query, [], [], state)
  end

  test "select with parameter", state do
    {:ok, state} = LibSqlEx.connect(state[:opts])

    query = %LibSqlEx.Query{
      statement: "SELECT ?1 + ?2"
    }

    assert {:ok, _, result, _} = LibSqlEx.handle_execute(query, [10, 5], [], state)
    assert result.rows == [[15]]
  end

  test "delete user and check it's gone", state do
    {:ok, state} = LibSqlEx.connect(state[:opts])

    # Create table first
    create_table = %LibSqlEx.Query{
      statement:
        "CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, email TEXT)"
    }

    {:ok, _, _, state} = LibSqlEx.handle_execute(create_table, [], [], state)

    insert_query = %LibSqlEx.Query{
      statement: "INSERT INTO users (name, email) VALUES (?1, ?2)"
    }

    {:ok, _, _, new_state} =
      LibSqlEx.handle_execute(insert_query, ["Bob", "bob@mail.com"], [], state)

    delete_query = %LibSqlEx.Query{
      statement: "DELETE FROM users WHERE name = ?1"
    }

    {:ok, _, _, final_state} = LibSqlEx.handle_execute(delete_query, ["Bob"], [], new_state)

    select_query = %LibSqlEx.Query{
      statement: "SELECT * FROM users WHERE name = ?1"
    }

    {:ok, _, result, _} = LibSqlEx.handle_execute(select_query, ["Bob"], [], final_state)

    assert result.rows == []
  end

  test "transaction rollback", state do
    {:ok, state} = LibSqlEx.connect(state[:opts])

    create_table = %LibSqlEx.Query{
      statement:
        "CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, email TEXT)"
    }

    {:ok, _, _, state} = LibSqlEx.handle_execute(create_table, [], [], state)

    {:ok, _, new_state} = LibSqlEx.handle_begin([], state)

    query = %LibSqlEx.Query{statement: "INSERT INTO users (name, email) values (?1, ?2)"}
    params = ["rollback_user", "rollback@mail.com"]

    {:ok, _, _, mid_state} = LibSqlEx.handle_execute(query, params, [], new_state)

    {:ok, _, rolled_back_state} = LibSqlEx.handle_rollback([], mid_state)

    # Pastikan data tidak masuk setelah rollback
    select_query = %LibSqlEx.Query{
      statement: "SELECT * FROM users WHERE name = ?1"
    }

    {:ok, _, result, _} =
      LibSqlEx.handle_execute(select_query, ["rollback_user"], [], rolled_back_state)

    assert result.rows == []
  end

  test "commit without active transaction", state do
    {:ok, state} = LibSqlEx.connect(state[:opts])

    assert {:error, _, _} = LibSqlEx.handle_commit([], state)
  end

  test "local no sync", _state do
    local = [
      database: "bar.db"
    ]

    {:ok, state} = LibSqlEx.connect(local)

    create_table = %LibSqlEx.Query{
      statement:
        "CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, email TEXT)"
    }

    {:ok, _, _, state} = LibSqlEx.handle_execute(create_table, [], [], state)

    query = %LibSqlEx.Query{statement: "INSERT INTO users (name, email) values (?1, ?2)"}

    params = ["danawanb", "nosync@gmail.com"]
    res_execute = LibSqlEx.handle_execute(query, params, [], state)

    assert {:ok, _, _, _} = res_execute

    # Skip remote connection test if env vars are not set
    if System.get_env("LIBSQL_URI") && System.get_env("LIBSQL_TOKEN") do
      remote_only = [
        uri: System.get_env("LIBSQL_URI"),
        auth_token: System.get_env("LIBSQL_TOKEN")
      ]

      {:ok, remote_state} = LibSqlEx.connect(remote_only)

      query_select = "SELECT * FROM users WHERE email = ? LIMIT 1"

      select_execute =
        LibSqlEx.handle_execute(query_select, ["nosync@gmail.com"], [], remote_state)

      assert {:ok, _, %LibSqlEx.Result{command: :select, columns: [], rows: [], num_rows: 0}, _} =
               select_execute
    end
  end

  test "manual sync", _state do
    local = [
      database: "bar.db"
    ]

    {:ok, state} = LibSqlEx.connect(local)

    create_table = %LibSqlEx.Query{
      statement:
        "CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, email TEXT)"
    }

    {:ok, _, _, state} = LibSqlEx.handle_execute(create_table, [], [], state)

    query = %LibSqlEx.Query{statement: "INSERT INTO users (name, email) values (?1, ?2)"}

    params = ["danawanb", "manualsync@gmail.com"]
    res_execute = LibSqlEx.handle_execute(query, params, [], state)

    assert {:ok, _, _, _} = res_execute

    remote_only = [
      uri: System.get_env("LIBSQL_URI"),
      auth_token: System.get_env("LIBSQL_TOKEN"),
      database: "bar.db"
    ]

    {:ok, remote_state} = LibSqlEx.connect(remote_only)

    syncx = LibSqlEx.Native.sync(remote_state)

    query_select = "SELECT * FROM users WHERE email = ? LIMIT 1"
    assert {:ok, "success sync"} = syncx

    select_execute =
      LibSqlEx.handle_execute(query_select, ["manualsync@gmail.com"], [], remote_state)

    assert {:ok, _, _, _} = select_execute
  end

  # Creative Tests - Advanced Features

  test "prepared statements with parameter binding", state do
    {:ok, state} = LibSqlEx.connect(state[:opts])

    # Create table with REAL for floats
    create_table = %LibSqlEx.Query{
      statement:
        "CREATE TABLE IF NOT EXISTS products (id INTEGER PRIMARY KEY, name TEXT, price REAL)"
    }

    {:ok, _, _, state} = LibSqlEx.handle_execute(create_table, [], [], state)

    # Insert data using floats (now supported!)
    {:ok, _, _, state} =
      LibSqlEx.handle_execute(
        "INSERT INTO products (name, price) VALUES (?, ?)",
        ["Widget", 19.99],
        [],
        state
      )

    {:ok, _, _, state} =
      LibSqlEx.handle_execute(
        "INSERT INTO products (name, price) VALUES (?, ?)",
        ["Gadget", 29.50],
        [],
        state
      )

    {:ok, _, _, state} =
      LibSqlEx.handle_execute(
        "INSERT INTO products (name, price) VALUES (?, ?)",
        ["Doohickey", 39.75],
        [],
        state
      )

    # Test prepared statement with parameter binding
    {:ok, select_stmt} = LibSqlEx.Native.prepare(state, "SELECT * FROM products WHERE name = ?")

    # Query with different parameters - testing parameter binding works
    {:ok, result1} = LibSqlEx.Native.query_stmt(state, select_stmt, ["Widget"])
    assert result1.num_rows == 1
    [[_id, name1, price1]] = result1.rows
    assert name1 == "Widget"
    assert price1 == 19.99

    {:ok, result2} = LibSqlEx.Native.query_stmt(state, select_stmt, ["Gadget"])
    assert result2.num_rows == 1
    [[_id, name2, price2]] = result2.rows
    assert name2 == "Gadget"
    assert price2 == 29.50

    {:ok, result3} = LibSqlEx.Native.query_stmt(state, select_stmt, ["Doohickey"])
    assert result3.num_rows == 1

    # Clean up
    assert :ok = LibSqlEx.Native.close_stmt(select_stmt)
  end

  test "batch operations - non-transactional", state do
    {:ok, state} = LibSqlEx.connect(state[:opts])

    # Create table
    create_table = %LibSqlEx.Query{
      statement: "CREATE TABLE IF NOT EXISTS batch_test (id INTEGER PRIMARY KEY, value TEXT)"
    }

    {:ok, _, _, state} = LibSqlEx.handle_execute(create_table, [], [], state)

    # Execute batch of statements
    statements = [
      {"INSERT INTO batch_test (value) VALUES (?)", ["first"]},
      {"INSERT INTO batch_test (value) VALUES (?)", ["second"]},
      {"INSERT INTO batch_test (value) VALUES (?)", ["third"]},
      {"SELECT COUNT(*) FROM batch_test", []}
    ]

    {:ok, results} = LibSqlEx.Native.batch(state, statements)

    # Should have 4 results (3 inserts + 1 select)
    assert length(results) == 4

    # Last result should be the count query
    count_result = List.last(results)
    # Extract the actual count value from the result rows
    [[count]] = count_result.rows
    assert count >= 3
  end

  test "batch operations - transactional atomicity with floats", state do
    {:ok, state} = LibSqlEx.connect(state[:opts])

    # Create table with REAL balance (floats now supported!)
    create_table = %LibSqlEx.Query{
      statement: "CREATE TABLE IF NOT EXISTS accounts (id INTEGER PRIMARY KEY, balance REAL)"
    }

    {:ok, _, _, state} = LibSqlEx.handle_execute(create_table, [], [], state)

    # Insert initial account with float
    {:ok, _, _, state} =
      LibSqlEx.handle_execute(
        "INSERT INTO accounts (id, balance) VALUES (?, ?)",
        [1, 100.50],
        [],
        state
      )

    # This batch should fail on the constraint violation and rollback everything
    statements = [
      {"UPDATE accounts SET balance = balance - 25.25 WHERE id = ?", [1]},
      # Duplicate key - will fail
      {"INSERT INTO accounts (id, balance) VALUES (?, ?)", [1, 50.00]}
    ]

    # Should return error
    assert {:error, _} = LibSqlEx.Native.batch_transactional(state, statements)

    # Verify balance wasn't changed (rollback worked)
    {:ok, _, result, _} =
      LibSqlEx.handle_execute(
        "SELECT balance FROM accounts WHERE id = ?",
        [1],
        [],
        state
      )

    [[balance]] = result.rows
    assert balance == 100.50
  end

  test "transaction behaviors - deferred and read_only", state do
    {:ok, state} = LibSqlEx.connect(state[:opts])

    # Test DEFERRED (default)
    {:ok, deferred_state} = LibSqlEx.Native.begin(state, behavior: :deferred)
    assert deferred_state.trx_id != nil
    {:ok, _} = LibSqlEx.Native.rollback(deferred_state)

    # Test READ_ONLY
    {:ok, readonly_state} = LibSqlEx.Native.begin(state, behavior: :read_only)
    assert readonly_state.trx_id != nil
    {:ok, _} = LibSqlEx.Native.rollback(readonly_state)
  end

  test "metadata functions - last_insert_rowid and changes", state do
    {:ok, state} = LibSqlEx.connect(state[:opts])

    # Create table
    create_table = %LibSqlEx.Query{
      statement:
        "CREATE TABLE IF NOT EXISTS metadata_test (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)"
    }

    {:ok, _, _, state} = LibSqlEx.handle_execute(create_table, [], [], state)

    # Insert and check rowid
    {:ok, _, _, state} =
      LibSqlEx.handle_execute(
        "INSERT INTO metadata_test (name) VALUES (?)",
        ["First"],
        [],
        state
      )

    rowid1 = LibSqlEx.Native.get_last_insert_rowid(state)
    changes1 = LibSqlEx.Native.get_changes(state)

    assert is_integer(rowid1)
    assert changes1 == 1

    # Insert another
    {:ok, _, _, state} =
      LibSqlEx.handle_execute(
        "INSERT INTO metadata_test (name) VALUES (?)",
        ["Second"],
        [],
        state
      )

    rowid2 = LibSqlEx.Native.get_last_insert_rowid(state)
    assert rowid2 > rowid1

    # Update multiple rows
    {:ok, _, _, state} =
      LibSqlEx.handle_execute(
        "UPDATE metadata_test SET name = ? WHERE id <= ?",
        ["Updated", rowid2],
        [],
        state
      )

    changes_update = LibSqlEx.Native.get_changes(state)
    assert changes_update == 2

    # Check total changes
    total = LibSqlEx.Native.get_total_changes(state)
    # At least 2 inserts + 2 updates
    assert total >= 4
  end

  test "is_autocommit check", state do
    {:ok, state} = LibSqlEx.connect(state[:opts])

    # Should be in autocommit mode initially
    assert LibSqlEx.Native.get_is_autocommit(state) == true

    # Start transaction
    {:ok, :begin, trx_state} = LibSqlEx.handle_begin([], state)

    # Should not be in autocommit during transaction
    assert LibSqlEx.Native.get_is_autocommit(trx_state) == false

    # Commit transaction
    {:ok, _, committed_state} = LibSqlEx.handle_commit([], trx_state)

    # Should be back in autocommit mode
    assert LibSqlEx.Native.get_is_autocommit(committed_state) == true
  end

  test "vector helpers - vector_type and vector_distance_cos", state do
    {:ok, state} = LibSqlEx.connect(state[:opts])

    # Test vector_type helper
    f32_type = LibSqlEx.Native.vector_type(128, :f32)
    assert f32_type == "F32_BLOB(128)"

    f64_type = LibSqlEx.Native.vector_type(256, :f64)
    assert f64_type == "F64_BLOB(256)"

    # Create table with vector column using helper
    vector_col = LibSqlEx.Native.vector_type(3, :f32)

    {:ok, _, _, state} =
      LibSqlEx.handle_execute(
        "CREATE TABLE IF NOT EXISTS embeddings (id INTEGER PRIMARY KEY, vec #{vector_col})",
        [],
        [],
        state
      )

    # Test vector helper
    vec1 = LibSqlEx.Native.vector([1.0, 2.0, 3.0])
    assert vec1 == "[1.0,2.0,3.0]"

    vec2 = LibSqlEx.Native.vector([4, 5, 6])
    assert vec2 == "[4,5,6]"

    # Insert vectors
    {:ok, _, _, state} =
      LibSqlEx.handle_execute(
        "INSERT INTO embeddings (id, vec) VALUES (?, vector(?))",
        [1, vec1],
        [],
        state
      )

    {:ok, _, _, state} =
      LibSqlEx.handle_execute(
        "INSERT INTO embeddings (id, vec) VALUES (?, vector(?))",
        [2, vec2],
        [],
        state
      )

    # Test vector_distance_cos helper
    distance_sql = LibSqlEx.Native.vector_distance_cos("vec", [1.5, 2.5, 3.5])
    assert String.contains?(distance_sql, "vector_distance_cos")
    assert String.contains?(distance_sql, "vec")

    # Use in query
    {:ok, _, result, _} =
      LibSqlEx.handle_execute(
        "SELECT id, #{distance_sql} as distance FROM embeddings ORDER BY distance LIMIT 1",
        [],
        [],
        state
      )

    assert result.num_rows == 1
  end

  test "batch with mixed operations", state do
    {:ok, state} = LibSqlEx.connect(state[:opts])

    # Create table
    {:ok, _, _, state} =
      LibSqlEx.handle_execute(
        "CREATE TABLE IF NOT EXISTS mixed_batch (id INTEGER PRIMARY KEY, val TEXT)",
        [],
        [],
        state
      )

    # Execute batch with inserts, updates, and selects
    statements = [
      {"INSERT INTO mixed_batch (id, val) VALUES (?, ?)", [1, "alpha"]},
      {"INSERT INTO mixed_batch (id, val) VALUES (?, ?)", [2, "beta"]},
      {"UPDATE mixed_batch SET val = ? WHERE id = ?", ["gamma", 1]},
      {"SELECT val FROM mixed_batch WHERE id = ?", [1]},
      {"DELETE FROM mixed_batch WHERE id = ?", [2]},
      {"SELECT COUNT(*) FROM mixed_batch", []}
    ]

    {:ok, results} = LibSqlEx.Native.batch_transactional(state, statements)

    # Should get results for all statements
    assert length(results) == 6

    # Fourth result should be the select showing "gamma"
    select_result = Enum.at(results, 3)
    assert select_result.rows == [["gamma"]]

    # Last result should show count of 1 (one deleted)
    count_result = List.last(results)
    assert hd(hd(count_result.rows)) == 1
  end

  test "large result set handling with batch insert", state do
    {:ok, state} = LibSqlEx.connect(state[:opts])

    # Create table
    {:ok, _, _, state} =
      LibSqlEx.handle_execute(
        "CREATE TABLE IF NOT EXISTS large_test (id INTEGER PRIMARY KEY, category TEXT, value INTEGER)",
        [],
        [],
        state
      )

    # Insert many rows using batch
    insert_statements =
      for i <- 1..100 do
        category = if rem(i, 2) == 0, do: "even", else: "odd"
        {"INSERT INTO large_test (id, category, value) VALUES (?, ?, ?)", [i, category, i * 10]}
      end

    {:ok, _} = LibSqlEx.Native.batch(state, insert_statements)

    # Query with filter
    {:ok, _, result, _} =
      LibSqlEx.handle_execute(
        "SELECT COUNT(*) FROM large_test WHERE category = ?",
        ["even"],
        [],
        state
      )

    [[count]] = result.rows
    assert count == 50
  end

  test "JSON data storage", state do
    {:ok, state} = LibSqlEx.connect(state[:opts])

    # Create table for JSON-like data
    {:ok, _, _, state} =
      LibSqlEx.handle_execute(
        "CREATE TABLE IF NOT EXISTS json_test (id INTEGER PRIMARY KEY, data TEXT)",
        [],
        [],
        state
      )

    # Store JSON-encoded data
    json_data = Jason.encode!(%{name: "Alice", age: 30, tags: ["developer", "elixir"]})

    {:ok, _, _, state} =
      LibSqlEx.handle_execute(
        "INSERT INTO json_test (data) VALUES (?)",
        [json_data],
        [],
        state
      )

    # Retrieve and decode
    {:ok, _, result, _} =
      LibSqlEx.handle_execute(
        "SELECT data FROM json_test LIMIT 1",
        [],
        [],
        state
      )

    [[retrieved_json]] = result.rows
    decoded = Jason.decode!(retrieved_json)

    assert decoded["name"] == "Alice"
    assert decoded["age"] == 30
    assert "developer" in decoded["tags"]
  end
end
