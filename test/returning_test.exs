defmodule EctoLibSql.ReturningTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, conn} = DBConnection.start_link(EctoLibSql, database: ":memory:")
    {:ok, conn: conn}
  end

  test "INSERT RETURNING returns columns and rows", %{conn: conn} do
    # Create table
    {:ok, _, _} =
      DBConnection.execute(
        conn,
        %EctoLibSql.Query{statement: "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT)"},
        []
      )

    # Insert with RETURNING
    query = %EctoLibSql.Query{statement: "INSERT INTO users (name, email) VALUES (?, ?) RETURNING id, name, email"}
    {:ok, _, result} = DBConnection.execute(conn, query, ["Alice", "alice@example.com"])

    IO.inspect(result, label: "INSERT RETURNING result")

    # Check structure
    assert result.columns != nil, "Columns should not be nil"
    assert result.rows != nil, "Rows should not be nil"
    assert length(result.columns) == 3, "Should have 3 columns"
    assert length(result.rows) == 1, "Should have 1 row"

    # Check values
    [[id, name, email]] = result.rows
    IO.puts("ID: #{inspect(id)}, Name: #{inspect(name)}, Email: #{inspect(email)}")

    assert is_integer(id), "ID should be integer"
    assert id > 0, "ID should be positive"
    assert name == "Alice", "Name should match"
    assert email == "alice@example.com", "Email should match"
  end

  test "INSERT RETURNING with timestamps", %{conn: conn} do
    # Create table with timestamps
    {:ok, _, _} =
      DBConnection.execute(
        conn,
        %EctoLibSql.Query{
          statement:
            "CREATE TABLE posts (id INTEGER PRIMARY KEY, title TEXT, inserted_at TEXT, updated_at TEXT)"
        },
        []
      )

    # Insert with RETURNING
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    query = %EctoLibSql.Query{
      statement:
        "INSERT INTO posts (title, inserted_at, updated_at) VALUES (?, ?, ?) RETURNING id, title, inserted_at, updated_at"
    }

    {:ok, _, result} = DBConnection.execute(conn, query, ["Test Post", now, now])

    IO.inspect(result, label: "INSERT RETURNING with timestamps")

    assert result.columns == ["id", "title", "inserted_at", "updated_at"]
    [[id, title, inserted_at, updated_at]] = result.rows

    IO.puts("ID: #{inspect(id)}")
    IO.puts("Title: #{inspect(title)}")
    IO.puts("inserted_at: #{inspect(inserted_at)}")
    IO.puts("updated_at: #{inspect(updated_at)}")

    assert is_integer(id)
    assert title == "Test Post"
    assert is_binary(inserted_at) or inserted_at == now
    assert is_binary(updated_at) or updated_at == now
  end
end
