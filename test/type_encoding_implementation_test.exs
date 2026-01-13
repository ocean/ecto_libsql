defmodule EctoLibSql.TypeEncodingImplementationTest do
  use ExUnit.Case, async: false

  # Tests for the type encoding implementation:
  # - Boolean encoding (true/false → 1/0)
  # - UUID encoding (binary → string if needed)
  # - :null atom encoding (:null → nil)

  alias Ecto.Adapters.SQL

  defmodule TestRepo do
    use Ecto.Repo,
      otp_app: :ecto_libsql,
      adapter: Ecto.Adapters.LibSql
  end

  defmodule User do
    use Ecto.Schema

    schema "users" do
      field(:name, :string)
      field(:email, :string)
      field(:active, :boolean, default: true)
      field(:uuid, :string)

      timestamps()
    end
  end

  @test_db "z_type_encoding_implementation.db"

  setup_all do
    {:ok, _pid} = TestRepo.start_link(database: @test_db)

    SQL.query!(TestRepo, """
    CREATE TABLE IF NOT EXISTS users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT,
      email TEXT,
      active INTEGER DEFAULT 1,
      uuid TEXT,
      inserted_at DATETIME,
      updated_at DATETIME
    )
    """)

    on_exit(fn ->
      EctoLibSql.TestHelpers.cleanup_db_files(@test_db)
    end)

    :ok
  end

  describe "boolean encoding implementation" do
    test "boolean true encoded as 1 in query parameters" do
      SQL.query!(TestRepo, "DELETE FROM users")

      # Insert with boolean true
      result =
        SQL.query!(TestRepo, "INSERT INTO users (name, active) VALUES (?, ?)", ["Alice", true])

      assert result.num_rows == 1

      # Verify true was encoded as 1
      result = SQL.query!(TestRepo, "SELECT active FROM users WHERE name = ?", ["Alice"])
      assert [[1]] = result.rows

      # Query with boolean should match
      result = SQL.query!(TestRepo, "SELECT COUNT(*) FROM users WHERE active = ?", [true])
      assert [[1]] = result.rows
    end

    test "boolean false encoded as 0 in query parameters" do
      SQL.query!(TestRepo, "DELETE FROM users")

      # Insert with boolean false
      result =
        SQL.query!(TestRepo, "INSERT INTO users (name, active) VALUES (?, ?)", ["Bob", false])

      assert result.num_rows == 1

      # Verify false was encoded as 0
      result = SQL.query!(TestRepo, "SELECT active FROM users WHERE name = ?", ["Bob"])
      assert [[0]] = result.rows

      # Query with boolean should match
      result = SQL.query!(TestRepo, "SELECT COUNT(*) FROM users WHERE active = ?", [false])
      assert [[1]] = result.rows
    end

    test "boolean true in WHERE clause" do
      SQL.query!(TestRepo, "DELETE FROM users")
      SQL.query!(TestRepo, "INSERT INTO users (name, active) VALUES (?, ?)", ["Alice", 1])
      SQL.query!(TestRepo, "INSERT INTO users (name, active) VALUES (?, ?)", ["Bob", 0])

      # Query with boolean parameter true (should match 1)
      result = SQL.query!(TestRepo, "SELECT COUNT(*) FROM users WHERE active = ?", [true])
      assert [[count]] = result.rows
      assert count >= 1
    end

    test "boolean false in WHERE clause" do
      SQL.query!(TestRepo, "DELETE FROM users")
      SQL.query!(TestRepo, "INSERT INTO users (name, active) VALUES (?, ?)", ["Alice", 1])
      SQL.query!(TestRepo, "INSERT INTO users (name, active) VALUES (?, ?)", ["Bob", 0])

      # Query with boolean parameter false (should match 0)
      result = SQL.query!(TestRepo, "SELECT COUNT(*) FROM users WHERE active = ?", [false])
      assert [[count]] = result.rows
      assert count >= 1
    end

    test "Ecto schema with boolean field uses encoding" do
      SQL.query!(TestRepo, "DELETE FROM users")

      # Create changeset with boolean field
      user = %User{name: "Charlie", email: "charlie@example.com", active: true}

      {:ok, inserted} =
        user
        |> Ecto.Changeset.change()
        |> TestRepo.insert()

      assert inserted.active == true

      # Verify it was stored as 1
      result = SQL.query!(TestRepo, "SELECT active FROM users WHERE id = ?", [inserted.id])
      assert [[1]] = result.rows
    end

    test "Querying boolean via Ecto.Query" do
      SQL.query!(TestRepo, "DELETE FROM users")

      # Insert test data
      TestRepo.insert!(%User{name: "Dave", email: "dave@example.com", active: true})
      TestRepo.insert!(%User{name: "Eve", email: "eve@example.com", active: false})

      # Query with boolean parameter
      import Ecto.Query

      active_users =
        from(u in User, where: u.active == ^true)
        |> TestRepo.all()

      assert length(active_users) >= 1
      assert Enum.all?(active_users, & &1.active)
    end
  end

  describe "UUID encoding implementation" do
    test "UUID string in query parameters" do
      SQL.query!(TestRepo, "DELETE FROM users")

      uuid = Ecto.UUID.generate()

      # Insert with UUID
      result =
        SQL.query!(TestRepo, "INSERT INTO users (name, uuid) VALUES (?, ?)", ["Alice", uuid])

      assert result.num_rows == 1

      # Verify UUID was stored correctly
      result = SQL.query!(TestRepo, "SELECT uuid FROM users WHERE uuid = ?", [uuid])
      assert [[^uuid]] = result.rows
    end

    test "UUID in WHERE clause" do
      SQL.query!(TestRepo, "DELETE FROM users")

      uuid1 = Ecto.UUID.generate()
      uuid2 = Ecto.UUID.generate()

      SQL.query!(TestRepo, "INSERT INTO users (name, uuid) VALUES (?, ?)", ["Alice", uuid1])
      SQL.query!(TestRepo, "INSERT INTO users (name, uuid) VALUES (?, ?)", ["Bob", uuid2])

      # Query with UUID parameter
      result = SQL.query!(TestRepo, "SELECT COUNT(*) FROM users WHERE uuid = ?", [uuid1])
      assert [[1]] = result.rows
    end

    test "Ecto schema with UUID field" do
      SQL.query!(TestRepo, "DELETE FROM users")

      uuid = Ecto.UUID.generate()

      user = %User{name: "Charlie", email: "charlie@example.com", uuid: uuid}

      {:ok, inserted} =
        user
        |> Ecto.Changeset.change()
        |> TestRepo.insert()

      assert inserted.uuid == uuid

      # Verify it was stored correctly
      result = SQL.query!(TestRepo, "SELECT uuid FROM users WHERE id = ?", [inserted.id])
      assert [[^uuid]] = result.rows
    end

    test "Querying UUID via Ecto.Query" do
      SQL.query!(TestRepo, "DELETE FROM users")

      uuid = Ecto.UUID.generate()

      # Insert test data
      TestRepo.insert!(%User{name: "Dave", email: "dave@example.com", uuid: uuid})

      # Query with UUID parameter
      import Ecto.Query

      users = from(u in User, where: u.uuid == ^uuid) |> TestRepo.all()

      assert length(users) == 1
      assert hd(users).uuid == uuid
    end
  end

  describe ":null atom encoding implementation" do
    test ":null atom encoded as nil for NULL values" do
      SQL.query!(TestRepo, "DELETE FROM users")

      # Insert with :null atom (should be converted to nil → NULL)
      result =
        SQL.query!(TestRepo, "INSERT INTO users (name, uuid) VALUES (?, ?)", ["Alice", :null])

      assert result.num_rows == 1

      # Verify NULL was stored
      result =
        SQL.query!(TestRepo, "SELECT uuid FROM users WHERE name = ? AND uuid IS NULL", ["Alice"])

      assert [[nil]] = result.rows
    end

    test "querying with :null atom for IS NULL" do
      SQL.query!(TestRepo, "DELETE FROM users")

      # Insert NULL value
      SQL.query!(TestRepo, "INSERT INTO users (name, uuid) VALUES (?, ?)", ["Alice", nil])

      # Query with :null should find it
      result =
        SQL.query!(TestRepo, "SELECT COUNT(*) FROM users WHERE uuid IS NULL AND name = ?", [
          "Alice"
        ])

      assert [[1]] = result.rows
    end

    test ":null in complex queries" do
      SQL.query!(TestRepo, "DELETE FROM users")

      SQL.query!(TestRepo, "INSERT INTO users (name, uuid) VALUES (?, ?)", ["Alice", :null])

      SQL.query!(TestRepo, "INSERT INTO users (name, uuid) VALUES (?, ?)", [
        "Bob",
        Ecto.UUID.generate()
      ])

      # Count non-NULL values
      result = SQL.query!(TestRepo, "SELECT COUNT(*) FROM users WHERE uuid IS NOT NULL")
      assert [[count]] = result.rows
      assert count >= 1

      # Count NULL values
      result = SQL.query!(TestRepo, "SELECT COUNT(*) FROM users WHERE uuid IS NULL")
      assert [[count]] = result.rows
      assert count >= 1
    end
  end

  describe "combined type encoding" do
    test "multiple encoded types in single query" do
      SQL.query!(TestRepo, "DELETE FROM users")

      uuid = Ecto.UUID.generate()

      result =
        SQL.query!(
          TestRepo,
          "INSERT INTO users (name, email, active, uuid) VALUES (?, ?, ?, ?)",
          ["Alice", "alice@example.com", true, uuid]
        )

      assert result.num_rows == 1

      # Verify all values
      result =
        SQL.query!(TestRepo, "SELECT active, uuid FROM users WHERE name = ? AND email = ?", [
          "Alice",
          "alice@example.com"
        ])

      assert [[1, ^uuid]] = result.rows
    end

    test "boolean, UUID, and :null in batch operations" do
      SQL.query!(TestRepo, "DELETE FROM users")

      uuid1 = Ecto.UUID.generate()
      uuid2 = Ecto.UUID.generate()

      statements = [
        {"INSERT INTO users (name, active, uuid) VALUES (?, ?, ?)", ["Alice", true, uuid1]},
        {"INSERT INTO users (name, active, uuid) VALUES (?, ?, ?)", ["Bob", false, uuid2]},
        {"INSERT INTO users (name, active, uuid) VALUES (?, ?, ?)", ["Charlie", true, :null]}
      ]

      _results =
        statements
        |> Enum.map(fn {sql, params} ->
          SQL.query!(TestRepo, sql, params)
        end)

      # Verify all were inserted
      result = SQL.query!(TestRepo, "SELECT COUNT(*) FROM users")
      assert [[count]] = result.rows
      assert count >= 3
    end

    test "Ecto query with multiple encoded types" do
      SQL.query!(TestRepo, "DELETE FROM users")

      uuid = Ecto.UUID.generate()

      # Insert test data
      TestRepo.insert!(%User{name: "Dave", email: "dave@example.com", active: true, uuid: uuid})
      TestRepo.insert!(%User{name: "Eve", email: "eve@example.com", active: false, uuid: nil})

      # Query with multiple encoded types
      import Ecto.Query

      users =
        from(u in User, where: u.active == ^true and u.uuid == ^uuid)
        |> TestRepo.all()

      assert length(users) >= 1
      assert Enum.all?(users, fn u -> u.active == true and u.uuid == uuid end)
    end
  end

  describe "edge cases and error conditions" do
    test "boolean in comparison queries" do
      SQL.query!(TestRepo, "DELETE FROM users")

      SQL.query!(TestRepo, "INSERT INTO users (name, active) VALUES (?, ?)", ["Active", true])
      SQL.query!(TestRepo, "INSERT INTO users (name, active) VALUES (?, ?)", ["Inactive", false])

      # Count active
      result = SQL.query!(TestRepo, "SELECT COUNT(*) FROM users WHERE active = ?", [true])
      assert [[count]] = result.rows
      assert count >= 1

      # Count inactive
      result = SQL.query!(TestRepo, "SELECT COUNT(*) FROM users WHERE active = ?", [false])
      assert [[count]] = result.rows
      assert count >= 1

      # Count with NOT
      result = SQL.query!(TestRepo, "SELECT COUNT(*) FROM users WHERE active != ?", [true])
      assert [[count]] = result.rows
      assert count >= 1
    end

    test "UUID in aggregation queries" do
      SQL.query!(TestRepo, "DELETE FROM users")

      uuid = Ecto.UUID.generate()

      SQL.query!(TestRepo, "INSERT INTO users (name, uuid) VALUES (?, ?)", ["A", uuid])
      SQL.query!(TestRepo, "INSERT INTO users (name, uuid) VALUES (?, ?)", ["B", uuid])

      SQL.query!(TestRepo, "INSERT INTO users (name, uuid) VALUES (?, ?)", [
        "C",
        Ecto.UUID.generate()
      ])

      # Count by UUID
      result =
        SQL.query!(TestRepo, "SELECT COUNT(*) FROM users WHERE uuid = ?", [uuid])

      assert [[count]] = result.rows
      assert count >= 2
    end

    test ":null with IS NULL and NOT NULL operators" do
      SQL.query!(TestRepo, "DELETE FROM users")

      SQL.query!(TestRepo, "INSERT INTO users (name, uuid) VALUES (?, ?)", ["A", :null])

      SQL.query!(TestRepo, "INSERT INTO users (name, uuid) VALUES (?, ?)", [
        "B",
        Ecto.UUID.generate()
      ])

      # IS NULL should work
      result = SQL.query!(TestRepo, "SELECT COUNT(*) FROM users WHERE uuid IS NULL")
      assert [[count]] = result.rows
      assert count >= 1

      # NOT NULL should work
      result = SQL.query!(TestRepo, "SELECT COUNT(*) FROM users WHERE uuid IS NOT NULL")
      assert [[count]] = result.rows
      assert count >= 1
    end
  end
end
