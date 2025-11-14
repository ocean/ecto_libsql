defmodule LibSqlExTest do
  use ExUnit.Case
  doctest LibSqlEx

  setup_all do
    opts = [
      uri: System.get_env("LIBSQL_URI"),
      auth_token: System.get_env("LIBSQL_TOKEN"),
      database: "bar.db",
      # sync is optional
      sync: true
    ]

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

    assert {:error, _, _, _} = LibSqlEx.handle_execute(query, [], [], state)
  end

  # passed
  @tag :skip
  test "insert and update user", state do
    {:ok, state} = LibSqlEx.connect(state[:opts])

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

    assert {:ok, _, result, _} =
             LibSqlEx.handle_execute(select_query, ["Alice"], [], final_state)

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

    {:ok, _, _, final_state} =
      LibSqlEx.handle_execute(delete_query, ["Bob"], [], new_state)

    select_query = %LibSqlEx.Query{
      statement: "SELECT * FROM users WHERE name = ?1"
    }

    {:ok, _, result, _} =
      LibSqlEx.handle_execute(select_query, ["Bob"], [], final_state)

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
    select_execute = LibSqlEx.handle_execute(query_select, ["nosync@gmail.com"], [], remote_state)

    assert {:ok, _, %LibSqlEx.Result{command: :select, columns: [], rows: [], num_rows: 0}, _} =
             select_execute
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
end
