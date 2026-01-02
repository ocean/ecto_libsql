defmodule EctoLibSql.NamedParametersExecutionTest do
  @moduledoc """
  Tests for named parameter execution support.

  Named parameters allow queries to accept map-based parameters instead of
  positional lists, making queries more readable and self-documenting.

  Supported syntaxes:
  - :name (colon prefix)
  - @name (at-sign prefix)
  - $name (dollar prefix)
  """

  use ExUnit.Case, async: false

  setup do
    db_name = "test_named_params_#{:rand.uniform(1_000_000_000_000)}"
    {:ok, state} = EctoLibSql.connect(database: db_name)

    # Create test table
    {:ok, _, _, state} =
      EctoLibSql.handle_execute(
        """
        CREATE TABLE users (
          id INTEGER PRIMARY KEY,
          name TEXT NOT NULL,
          email TEXT NOT NULL,
          age INTEGER
        )
        """,
        [],
        [],
        state
      )

    on_exit(fn ->
      File.rm(db_name)
      File.rm(db_name <> "-wal")
      File.rm(db_name <> "-shm")
      File.rm(db_name <> "-journal")
    end)

    {:ok, state: state, db_name: db_name}
  end

  describe "Named parameters with colon prefix (:name)" do
    test "INSERT with named parameters", %{state: state} do
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO users (id, name, email, age) VALUES (:id, :name, :email, :age)",
          %{id: 1, name: "Alice", email: "alice@example.com", age: 30},
          [],
          state
        )

      # Verify insert worked
      {:ok, _, result, _} =
        EctoLibSql.handle_execute(
          "SELECT * FROM users WHERE id = :id",
          %{id: 1},
          [],
          state
        )

      assert result.num_rows == 1
      [[1, "Alice", "alice@example.com", 30]] = result.rows
    end

    test "SELECT with named parameters", %{state: state} do
      # Insert test data
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO users (id, name, email, age) VALUES (:id, :name, :email, :age)",
          %{id: 1, name: "Alice", email: "alice@example.com", age: 30},
          [],
          state
        )

      # Query with named parameters
      {:ok, _, result, _} =
        EctoLibSql.handle_execute(
          "SELECT * FROM users WHERE name = :name AND age = :age",
          %{name: "Alice", age: 30},
          [],
          state
        )

      assert result.num_rows == 1
      [[1, "Alice", "alice@example.com", 30]] = result.rows
    end

    test "UPDATE with named parameters", %{state: state} do
      # Insert test data
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO users (id, name, email, age) VALUES (:id, :name, :email, :age)",
          %{id: 1, name: "Alice", email: "alice@example.com", age: 30},
          [],
          state
        )

      # Update with named parameters
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "UPDATE users SET age = :new_age WHERE id = :id",
          %{id: 1, new_age: 31},
          [],
          state
        )

      # Verify update
      {:ok, _, result, _} =
        EctoLibSql.handle_execute(
          "SELECT age FROM users WHERE id = :id",
          %{id: 1},
          [],
          state
        )

      [[31]] = result.rows
    end

    test "DELETE with named parameters", %{state: state} do
      # Insert test data
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO users (id, name, email, age) VALUES (:id, :name, :email, :age)",
          %{id: 1, name: "Alice", email: "alice@example.com", age: 30},
          [],
          state
        )

      # Delete with named parameters
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "DELETE FROM users WHERE id = :id",
          %{id: 1},
          [],
          state
        )

      # Verify delete
      {:ok, _, result, _} =
        EctoLibSql.handle_execute(
          "SELECT COUNT(*) FROM users",
          [],
          [],
          state
        )

      [[0]] = result.rows
    end

    test "Multiple inserts with reused statement", %{state: state} do
      # First insert
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO users (id, name, email, age) VALUES (:id, :name, :email, :age)",
          %{id: 1, name: "Alice", email: "alice@example.com", age: 30},
          [],
          state
        )

      # Second insert
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO users (id, name, email, age) VALUES (:id, :name, :email, :age)",
          %{id: 2, name: "Bob", email: "bob@example.com", age: 25},
          [],
          state
        )

      # Verify both records exist
      {:ok, _, result, _} =
        EctoLibSql.handle_execute(
          "SELECT COUNT(*) FROM users",
          [],
          [],
          state
        )

      [[2]] = result.rows
    end
  end

  describe "Named parameters with at prefix (@name)" do
    test "INSERT with @ prefix", %{state: state} do
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO users (id, name, email, age) VALUES (@id, @name, @email, @age)",
          %{id: 1, name: "Charlie", email: "charlie@example.com", age: 35},
          [],
          state
        )

      # Verify insert
      {:ok, _, result, _} =
        EctoLibSql.handle_execute(
          "SELECT * FROM users WHERE id = @id",
          %{id: 1},
          [],
          state
        )

      assert result.num_rows == 1
      [[1, "Charlie", "charlie@example.com", 35]] = result.rows
    end

    test "SELECT with @ prefix", %{state: state} do
      # Insert test data
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO users (id, name, email, age) VALUES (@id, @name, @email, @age)",
          %{id: 1, name: "David", email: "david@example.com", age: 40},
          [],
          state
        )

      # Query with @ prefix
      {:ok, _, result, _} =
        EctoLibSql.handle_execute(
          "SELECT * FROM users WHERE email = @email",
          %{email: "david@example.com"},
          [],
          state
        )

      assert result.num_rows == 1
    end
  end

  describe "Named parameters with dollar prefix ($name)" do
    test "INSERT with $ prefix", %{state: state} do
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO users (id, name, email, age) VALUES ($id, $name, $email, $age)",
          %{id: 1, name: "Eve", email: "eve@example.com", age: 28},
          [],
          state
        )

      # Verify insert
      {:ok, _, result, _} =
        EctoLibSql.handle_execute(
          "SELECT * FROM users WHERE id = $id",
          %{id: 1},
          [],
          state
        )

      assert result.num_rows == 1
      [[1, "Eve", "eve@example.com", 28]] = result.rows
    end

    test "SELECT with $ prefix", %{state: state} do
      # Insert test data
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO users (id, name, email, age) VALUES ($id, $name, $email, $age)",
          %{id: 1, name: "Frank", email: "frank@example.com", age: 45},
          [],
          state
        )

      # Query with $ prefix
      {:ok, _, result, _} =
        EctoLibSql.handle_execute(
          "SELECT * FROM users WHERE age > $min_age",
          %{min_age: 40},
          [],
          state
        )

      assert result.num_rows == 1
    end
  end

  describe "Backward compatibility with positional parameters" do
    test "Positional parameters still work (list)", %{state: state} do
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO users (id, name, email, age) VALUES (?, ?, ?, ?)",
          [1, "Grace", "grace@example.com", 32],
          [],
          state
        )

      # Verify insert
      {:ok, _, result, _} =
        EctoLibSql.handle_execute(
          "SELECT * FROM users WHERE id = ?",
          [1],
          [],
          state
        )

      assert result.num_rows == 1
      [[1, "Grace", "grace@example.com", 32]] = result.rows
    end

    test "Empty parameters work", %{state: state} do
      {:ok, _, result, _} =
        EctoLibSql.handle_execute(
          "SELECT 1 as num",
          [],
          [],
          state
        )

      assert result.num_rows == 1
      [[1]] = result.rows
    end
  end

  describe "Transactions with named parameters" do
    test "Named parameters in transactions", %{state: initial_state} do
      {:ok, state} = EctoLibSql.Native.begin(initial_state)

      # Insert in transaction with named params
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO users (id, name, email, age) VALUES (:id, :name, :email, :age)",
          %{id: 1, name: "Henry", email: "henry@example.com", age: 50},
          [],
          state
        )

      # Query in transaction
      {:ok, _, result, state} =
        EctoLibSql.handle_execute(
          "SELECT * FROM users WHERE name = :name",
          %{name: "Henry"},
          [],
          state
        )

      assert result.num_rows == 1

      {:ok, _} = EctoLibSql.Native.commit(state)

      # Verify persist - use original state which is now out of transaction
      {:ok, _, result, _} =
        EctoLibSql.handle_execute(
          "SELECT COUNT(*) FROM users",
          [],
          [],
          initial_state
        )

      [[1]] = result.rows
    end

    test "Named parameters rollback", %{state: initial_state} do
      {:ok, state} = EctoLibSql.Native.begin(initial_state)

      # Insert in transaction
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO users (id, name, email, age) VALUES (:id, :name, :email, :age)",
          %{id: 1, name: "Iris", email: "iris@example.com", age: 27},
          [],
          state
        )

      # Rollback
      {:ok, _} = EctoLibSql.Native.rollback(state)

      # Verify rolled back - use original state which is now out of transaction
      {:ok, _, result, _} =
        EctoLibSql.handle_execute(
          "SELECT COUNT(*) FROM users",
          [],
          [],
          initial_state
        )

      [[0]] = result.rows
    end
  end

  describe "Prepared statements with named parameters" do
    test "Prepared statement with named parameters introspection", %{state: state} do
      # Prepare statement.
      {:ok, stmt_id} =
        EctoLibSql.Native.prepare(
          state,
          "INSERT INTO users (id, name, email, age) VALUES (:id, :name, :email, :age)"
        )

      # Introspect parameter names.
      {:ok, param1} = EctoLibSql.Native.stmt_parameter_name(state, stmt_id, 1)
      {:ok, param2} = EctoLibSql.Native.stmt_parameter_name(state, stmt_id, 2)
      {:ok, param3} = EctoLibSql.Native.stmt_parameter_name(state, stmt_id, 3)
      {:ok, param4} = EctoLibSql.Native.stmt_parameter_name(state, stmt_id, 4)

      assert param1 == ":id"
      assert param2 == ":name"
      assert param3 == ":email"
      assert param4 == ":age"

      EctoLibSql.Native.close_stmt(stmt_id)
    end

    test "execute_stmt with atom-keyed map parameters", %{state: state} do
      sql = "INSERT INTO users (id, name, email, age) VALUES (:id, :name, :email, :age)"
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, sql)

      # Execute with a map of atom keys (named parameters).
      {:ok, 1} =
        EctoLibSql.Native.execute_stmt(state, stmt_id, sql, %{
          id: 1,
          name: "NamedTest",
          email: "named@test.com",
          age: 42
        })

      EctoLibSql.Native.close_stmt(stmt_id)

      # Verify the insert worked.
      {:ok, _, result, _} =
        EctoLibSql.handle_execute(
          "SELECT * FROM users WHERE id = 1",
          [],
          [],
          state
        )

      assert result.num_rows == 1
      [[1, "NamedTest", "named@test.com", 42]] = result.rows
    end

    test "query_stmt with atom-keyed map parameters", %{state: state} do
      # Insert test data first.
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO users (id, name, email, age) VALUES (1, 'QueryTest', 'query@test.com', 33)",
          [],
          [],
          state
        )

      # Prepare a SELECT with named parameter.
      sql = "SELECT * FROM users WHERE id = :id"
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, sql)

      # Query with a map of atom keys.
      {:ok, result} = EctoLibSql.Native.query_stmt(state, stmt_id, %{id: 1})

      assert result.num_rows == 1
      [[1, "QueryTest", "query@test.com", 33]] = result.rows

      EctoLibSql.Native.close_stmt(stmt_id)
    end

    test "prepared statement functions still work with positional lists", %{state: state} do
      # Ensure backward compatibility - positional lists should still work.
      sql = "INSERT INTO users (id, name, email, age) VALUES (?, ?, ?, ?)"
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, sql)

      {:ok, 1} =
        EctoLibSql.Native.execute_stmt(state, stmt_id, sql, [2, "PosList", "pos@list.com", 25])

      EctoLibSql.Native.close_stmt(stmt_id)

      # Verify.
      {:ok, _, result, _} =
        EctoLibSql.handle_execute(
          "SELECT * FROM users WHERE id = 2",
          [],
          [],
          state
        )

      assert result.num_rows == 1
      [[2, "PosList", "pos@list.com", 25]] = result.rows
    end
  end

  describe "Edge cases and error handling" do
    test "Missing named parameter raises clear error", %{state: state} do
      # Try to execute with missing parameter
      result =
        EctoLibSql.handle_execute(
          "INSERT INTO users (id, name, email, age) VALUES (:id, :name, :email, :age)",
          %{id: 1, name: "Jack"},
          [],
          state
        )

      # Should fail because :email and :age are missing
      assert match?({:error, _, _}, result)
    end

    test "Extra parameters in map are ignored", %{state: state} do
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO users (id, name, email, age) VALUES (:id, :name, :email, :age)",
          %{
            id: 1,
            name: "Karen",
            email: "karen@example.com",
            age: 29,
            extra: "ignored",
            another: "also ignored"
          },
          [],
          state
        )

      # Verify insert succeeded
      {:ok, _, result, _} =
        EctoLibSql.handle_execute(
          "SELECT * FROM users WHERE id = :id",
          %{id: 1},
          [],
          state
        )

      assert result.num_rows == 1
    end

    test "Named parameters with NULL values", %{state: state} do
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO users (id, name, email, age) VALUES (:id, :name, :email, :age)",
          %{id: 1, name: "Leo", email: "leo@example.com", age: nil},
          [],
          state
        )

      # Verify insert with NULLs
      {:ok, _, result, _} =
        EctoLibSql.handle_execute(
          "SELECT * FROM users WHERE id = :id",
          %{id: 1},
          [],
          state
        )

      assert result.num_rows == 1
      [[1, "Leo", "leo@example.com", nil]] = result.rows
    end

    test "Named parameters are case-sensitive", %{state: state} do
      # Insert with lowercase parameter names.
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO users (id, name, email, age) VALUES (:id, :name, :email, :age)",
          %{id: 1, name: "Mike", email: "mike@example.com", age: 35},
          [],
          state
        )

      # Query using :Name (uppercase N) in SQL but provide :name (lowercase) in params.
      # The parameter should NOT match due to case sensitivity.
      {:ok, _, result, _} =
        EctoLibSql.handle_execute(
          "SELECT * FROM users WHERE name = :Name",
          %{name: "Mike"},
          [],
          state
        )

      # Should find no rows because :Name != :name.
      assert result.num_rows == 0

      # Now use matching case - should work.
      {:ok, _, result, _} =
        EctoLibSql.handle_execute(
          "SELECT * FROM users WHERE name = :name",
          %{name: "Mike"},
          [],
          state
        )

      assert result.num_rows == 1
    end
  end
end
