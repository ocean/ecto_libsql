defmodule EctoLibSql.TypeEncodingImplementationTest do
  use ExUnit.Case, async: false

  # Tests for the type encoding implementation:
  # - Boolean encoding (true/false → 1/0)
  # - UUID encoding (binary → string if needed)
  # - :null atom encoding (:null → nil)

  import Ecto.Query
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
      # Exact count: one row with active=1 matches boolean true
      assert count == 1
    end

    test "boolean false in WHERE clause" do
      SQL.query!(TestRepo, "DELETE FROM users")
      SQL.query!(TestRepo, "INSERT INTO users (name, active) VALUES (?, ?)", ["Alice", 1])
      SQL.query!(TestRepo, "INSERT INTO users (name, active) VALUES (?, ?)", ["Bob", 0])

      # Query with boolean parameter false (should match 0)
      result = SQL.query!(TestRepo, "SELECT COUNT(*) FROM users WHERE active = ?", [false])
      assert [[count]] = result.rows
      # Exact count: one row with active=0 matches boolean false
      assert count == 1
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
      active_users = TestRepo.all(from(u in User, where: u.active == ^true))

      assert length(active_users) == 1
      assert hd(active_users).name == "Dave"
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
      users = TestRepo.all(from(u in User, where: u.uuid == ^uuid))

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

    test "nil inserted value can be queried with IS NULL" do
      SQL.query!(TestRepo, "DELETE FROM users")

      # Insert NULL value
      SQL.query!(TestRepo, "INSERT INTO users (name, uuid) VALUES (?, ?)", ["Alice", nil])

      # Query with IS NULL should find it
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
      assert count == 1

      # Count NULL values
      result = SQL.query!(TestRepo, "SELECT COUNT(*) FROM users WHERE uuid IS NULL")
      assert [[count]] = result.rows
      assert count == 1
    end
  end

  describe "nil value encoding" do
    test "nil boolean encoded correctly" do
      SQL.query!(TestRepo, "DELETE FROM users")

      # Insert with nil boolean
      result =
        SQL.query!(TestRepo, "INSERT INTO users (name, active) VALUES (?, ?)", ["Alice", nil])

      assert result.num_rows == 1

      # Verify NULL was stored
      result = SQL.query!(TestRepo, "SELECT active FROM users WHERE name = ?", ["Alice"])
      assert [[nil]] = result.rows
    end

    test "nil date encoded correctly" do
      # Create table if not exists
      SQL.query!(TestRepo, """
      CREATE TABLE IF NOT EXISTS test_dates (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT,
        birth_date DATE
      )
      """)

      SQL.query!(TestRepo, "DELETE FROM test_dates")

      # Insert with nil date
      result =
        SQL.query!(TestRepo, "INSERT INTO test_dates (name, birth_date) VALUES (?, ?)", [
          "Alice",
          nil
        ])

      assert result.num_rows == 1

      # Verify NULL was stored
      result = SQL.query!(TestRepo, "SELECT birth_date FROM test_dates WHERE name = ?", ["Alice"])
      assert [[nil]] = result.rows
    end

    test "nil time encoded correctly" do
      # Create table if not exists
      SQL.query!(TestRepo, """
      CREATE TABLE IF NOT EXISTS test_times (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT,
        start_time TIME
      )
      """)

      SQL.query!(TestRepo, "DELETE FROM test_times")

      # Insert with nil time
      result =
        SQL.query!(TestRepo, "INSERT INTO test_times (name, start_time) VALUES (?, ?)", [
          "Alice",
          nil
        ])

      assert result.num_rows == 1

      # Verify NULL was stored
      result = SQL.query!(TestRepo, "SELECT start_time FROM test_times WHERE name = ?", ["Alice"])
      assert [[nil]] = result.rows
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
        Enum.map(statements, fn {sql, params} ->
          SQL.query!(TestRepo, sql, params)
        end)

      # Verify all were inserted
      result = SQL.query!(TestRepo, "SELECT COUNT(*) FROM users")
      assert [[count]] = result.rows
      assert count == 3
    end

    test "Ecto query with multiple encoded types" do
      SQL.query!(TestRepo, "DELETE FROM users")

      uuid = Ecto.UUID.generate()

      # Insert test data
      TestRepo.insert!(%User{name: "Dave", email: "dave@example.com", active: true, uuid: uuid})
      TestRepo.insert!(%User{name: "Eve", email: "eve@example.com", active: false, uuid: nil})

      # Query with multiple encoded types
      users = TestRepo.all(from(u in User, where: u.active == ^true and u.uuid == ^uuid))

      assert length(users) == 1
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
      assert count == 1

      # Count inactive
      result = SQL.query!(TestRepo, "SELECT COUNT(*) FROM users WHERE active = ?", [false])
      assert [[count]] = result.rows
      assert count == 1

      # Count with NOT
      result = SQL.query!(TestRepo, "SELECT COUNT(*) FROM users WHERE active != ?", [true])
      assert [[count]] = result.rows
      assert count == 1
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
      assert count == 2
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
      assert count == 1

      # NOT NULL should work
      result = SQL.query!(TestRepo, "SELECT COUNT(*) FROM users WHERE uuid IS NOT NULL")
      assert [[count]] = result.rows
      assert count == 1
    end
  end

  describe "string encoding edge cases" do
    setup do
      SQL.query!(TestRepo, "DROP TABLE IF EXISTS test_types")

      SQL.query!(TestRepo, """
      CREATE TABLE test_types (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        text_col TEXT,
        blob_col BLOB,
        int_col INTEGER,
        real_col REAL
      )
      """)

      on_exit(fn ->
        SQL.query!(TestRepo, "DROP TABLE IF EXISTS test_types")
      end)

      :ok
    end

    test "empty string encoding" do
      result = SQL.query!(TestRepo, "INSERT INTO test_types (text_col) VALUES (?)", [""])
      assert result.num_rows == 1

      result = SQL.query!(TestRepo, "SELECT text_col FROM test_types WHERE text_col = ?", [""])
      assert [[""]] = result.rows
    end

    test "special characters in string - quotes and escapes" do
      special = "Test: 'single' \"double\" and \\ backslash"

      result = SQL.query!(TestRepo, "INSERT INTO test_types (text_col) VALUES (?)", [special])
      assert result.num_rows == 1

      result = SQL.query!(TestRepo, "SELECT text_col FROM test_types ORDER BY id DESC LIMIT 1")
      [[stored]] = result.rows
      assert stored == special
    end

    test "unicode characters in string" do
      unicode = "Unicode: 你好 مرحبا 🎉 🚀"

      result = SQL.query!(TestRepo, "INSERT INTO test_types (text_col) VALUES (?)", [unicode])
      assert result.num_rows == 1

      result = SQL.query!(TestRepo, "SELECT text_col FROM test_types ORDER BY id DESC LIMIT 1")
      [[stored]] = result.rows
      assert stored == unicode
    end

    test "newlines and whitespace in string" do
      whitespace = "Line 1\nLine 2\tTabbed\r\nWindows line"

      result = SQL.query!(TestRepo, "INSERT INTO test_types (text_col) VALUES (?)", [whitespace])
      assert result.num_rows == 1

      result = SQL.query!(TestRepo, "SELECT text_col FROM test_types ORDER BY id DESC LIMIT 1")
      [[stored]] = result.rows
      assert stored == whitespace
    end
  end

  describe "binary encoding edge cases" do
    setup do
      SQL.query!(TestRepo, "DROP TABLE IF EXISTS test_types")

      SQL.query!(TestRepo, """
      CREATE TABLE test_types (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        blob_col BLOB
      )
      """)

      on_exit(fn ->
        SQL.query!(TestRepo, "DROP TABLE IF EXISTS test_types")
      end)

      :ok
    end

    test "binary data with null bytes preserved" do
      binary = <<0, 1, 2, 255, 254, 253>>

      result = SQL.query!(TestRepo, "INSERT INTO test_types (blob_col) VALUES (?)", [binary])
      assert result.num_rows == 1

      result = SQL.query!(TestRepo, "SELECT blob_col FROM test_types ORDER BY id DESC LIMIT 1")
      assert [[^binary]] = result.rows
    end

    test "large binary data" do
      # Test with 1MB binary to meaningfully test large data handling
      binary = :crypto.strong_rand_bytes(1024 * 1024)

      result = SQL.query!(TestRepo, "INSERT INTO test_types (blob_col) VALUES (?)", [binary])
      assert result.num_rows == 1

      result = SQL.query!(TestRepo, "SELECT blob_col FROM test_types ORDER BY id DESC LIMIT 1")
      # Use exact pin matching to verify data integrity, not just size
      assert [[^binary]] = result.rows
    end

    test "binary with mixed bytes" do
      binary = :crypto.strong_rand_bytes(256)

      result = SQL.query!(TestRepo, "INSERT INTO test_types (blob_col) VALUES (?)", [binary])
      assert result.num_rows == 1

      result = SQL.query!(TestRepo, "SELECT blob_col FROM test_types ORDER BY id DESC LIMIT 1")
      assert [[^binary]] = result.rows
    end
  end

  describe "numeric encoding edge cases" do
    setup do
      SQL.query!(TestRepo, "DROP TABLE IF EXISTS test_types")

      SQL.query!(TestRepo, """
      CREATE TABLE test_types (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        int_col INTEGER,
        real_col REAL,
        text_col TEXT
      )
      """)

      on_exit(fn ->
        SQL.query!(TestRepo, "DROP TABLE IF EXISTS test_types")
      end)

      :ok
    end

    test "very large integer" do
      large_int = 9_223_372_036_854_775_807

      result = SQL.query!(TestRepo, "INSERT INTO test_types (int_col) VALUES (?)", [large_int])
      assert result.num_rows == 1

      result = SQL.query!(TestRepo, "SELECT int_col FROM test_types ORDER BY id DESC LIMIT 1")
      assert [[^large_int]] = result.rows
    end

    test "negative large integer" do
      large_negative = -9_223_372_036_854_775_808

      result =
        SQL.query!(TestRepo, "INSERT INTO test_types (int_col) VALUES (?)", [large_negative])

      assert result.num_rows == 1

      result = SQL.query!(TestRepo, "SELECT int_col FROM test_types ORDER BY id DESC LIMIT 1")
      assert [[^large_negative]] = result.rows
    end

    test "zero values" do
      SQL.query!(TestRepo, "INSERT INTO test_types (int_col) VALUES (?)", [0])
      SQL.query!(TestRepo, "INSERT INTO test_types (real_col) VALUES (?)", [0.0])

      result =
        SQL.query!(TestRepo, "SELECT int_col FROM test_types WHERE int_col = ?", [0])

      assert [[0]] = result.rows

      result =
        SQL.query!(TestRepo, "SELECT real_col FROM test_types WHERE real_col = ?", [0.0])

      [[stored_real]] = result.rows
      # Float comparison: +0.0 == -0.0 in Elixir
      assert stored_real == 0.0
    end

    test "Decimal parameter encoding" do
      decimal = Decimal.new("123.45")

      result = SQL.query!(TestRepo, "INSERT INTO test_types (text_col) VALUES (?)", [decimal])
      assert result.num_rows == 1

      decimal_str = Decimal.to_string(decimal)

      result =
        SQL.query!(TestRepo, "SELECT text_col FROM test_types WHERE text_col = ?", [decimal_str])

      assert result.rows != []
      [[stored]] = result.rows
      assert stored == decimal_str
    end

    test "Negative Decimal" do
      decimal = Decimal.new("-456.789")

      result = SQL.query!(TestRepo, "INSERT INTO test_types (text_col) VALUES (?)", [decimal])
      assert result.num_rows == 1

      decimal_str = Decimal.to_string(decimal)

      result =
        SQL.query!(TestRepo, "SELECT text_col FROM test_types WHERE text_col = ?", [decimal_str])

      assert result.rows != []
      [[stored]] = result.rows
      assert stored == decimal_str
    end
  end

  describe "temporal type encoding" do
    setup do
      SQL.query!(TestRepo, "DROP TABLE IF EXISTS test_types")

      SQL.query!(TestRepo, """
      CREATE TABLE test_types (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        text_col TEXT
      )
      """)

      on_exit(fn ->
        SQL.query!(TestRepo, "DROP TABLE IF EXISTS test_types")
      end)

      :ok
    end

    test "DateTime parameter encoding" do
      dt = DateTime.utc_now()
      expected_iso8601 = DateTime.to_iso8601(dt)

      result = SQL.query!(TestRepo, "INSERT INTO test_types (text_col) VALUES (?)", [dt])
      assert result.num_rows == 1

      result = SQL.query!(TestRepo, "SELECT text_col FROM test_types ORDER BY id DESC LIMIT 1")
      assert [[stored]] = result.rows
      # Verify exact ISO8601 format, not just LIKE pattern
      assert stored == expected_iso8601
    end

    test "NaiveDateTime parameter encoding" do
      dt = NaiveDateTime.utc_now()
      expected_iso8601 = NaiveDateTime.to_iso8601(dt)

      result = SQL.query!(TestRepo, "INSERT INTO test_types (text_col) VALUES (?)", [dt])
      assert result.num_rows == 1

      result = SQL.query!(TestRepo, "SELECT text_col FROM test_types ORDER BY id DESC LIMIT 1")
      assert [[stored]] = result.rows
      # Verify exact ISO8601 format, not just LIKE pattern
      assert stored == expected_iso8601
    end

    test "Date parameter encoding" do
      date = Date.utc_today()
      expected_iso8601 = Date.to_iso8601(date)

      result = SQL.query!(TestRepo, "INSERT INTO test_types (text_col) VALUES (?)", [date])
      assert result.num_rows == 1

      result = SQL.query!(TestRepo, "SELECT text_col FROM test_types ORDER BY id DESC LIMIT 1")
      assert [[stored]] = result.rows
      # Verify exact ISO8601 format (YYYY-MM-DD), not just LIKE pattern
      assert stored == expected_iso8601
    end

    test "Time parameter encoding" do
      time = Time.new!(14, 30, 45)
      expected_iso8601 = Time.to_iso8601(time)

      result = SQL.query!(TestRepo, "INSERT INTO test_types (text_col) VALUES (?)", [time])
      assert result.num_rows == 1

      result = SQL.query!(TestRepo, "SELECT text_col FROM test_types ORDER BY id DESC LIMIT 1")
      assert [[stored]] = result.rows
      # Verify exact ISO8601 format (HH:MM:SS.ffffff), not just LIKE pattern
      assert stored == expected_iso8601
    end
  end

  describe "float/real field encoding" do
    setup do
      SQL.query!(TestRepo, "DROP TABLE IF EXISTS test_types")

      SQL.query!(TestRepo, """
      CREATE TABLE test_types (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       real_col REAL
      )
      """)

      on_exit(fn ->
        SQL.query!(TestRepo, "DROP TABLE IF EXISTS test_types")
      end)

      :ok
    end

    test "positive float parameter encoding" do
      float_val = 3.14159

      result = SQL.query!(TestRepo, "INSERT INTO test_types (real_col) VALUES (?)", [float_val])
      assert result.num_rows == 1

      result = SQL.query!(TestRepo, "SELECT real_col FROM test_types ORDER BY id DESC LIMIT 1")
      assert [[stored]] = result.rows
      # Floating point comparison allows small precision differences
      assert abs(stored - float_val) < 0.00001
    end

    test "negative float parameter encoding" do
      float_val = -2.71828

      result = SQL.query!(TestRepo, "INSERT INTO test_types (real_col) VALUES (?)", [float_val])
      assert result.num_rows == 1

      result = SQL.query!(TestRepo, "SELECT real_col FROM test_types ORDER BY id DESC LIMIT 1")
      assert [[stored]] = result.rows
      assert abs(stored - float_val) < 0.00001
    end

    test "very small float" do
      float_val = 0.0000001

      result = SQL.query!(TestRepo, "INSERT INTO test_types (real_col) VALUES (?)", [float_val])
      assert result.num_rows == 1

      result = SQL.query!(TestRepo, "SELECT real_col FROM test_types ORDER BY id DESC LIMIT 1")
      assert [[stored]] = result.rows
      assert is_float(stored)
    end

    test "very large float" do
      float_val = 12_345_678_900.0

      result = SQL.query!(TestRepo, "INSERT INTO test_types (real_col) VALUES (?)", [float_val])
      assert result.num_rows == 1

      result = SQL.query!(TestRepo, "SELECT real_col FROM test_types ORDER BY id DESC LIMIT 1")
      assert [[stored]] = result.rows
      assert is_float(stored)
      assert stored > 1.0e9
    end

    test "float zero" do
      result = SQL.query!(TestRepo, "INSERT INTO test_types (real_col) VALUES (?)", [0.0])
      assert result.num_rows == 1

      result = SQL.query!(TestRepo, "SELECT real_col FROM test_types WHERE real_col = ?", [0.0])
      assert [[stored]] = result.rows
      assert stored == 0.0
    end

    test "float in WHERE clause comparison" do
      SQL.query!(TestRepo, "INSERT INTO test_types (real_col) VALUES (?)", [1.5])
      SQL.query!(TestRepo, "INSERT INTO test_types (real_col) VALUES (?)", [2.7])
      SQL.query!(TestRepo, "INSERT INTO test_types (real_col) VALUES (?)", [0.8])

      result =
        SQL.query!(TestRepo, "SELECT COUNT(*) FROM test_types WHERE real_col > ?", [1.0])

      assert [[count]] = result.rows
      assert count == 2
    end

    test "float in aggregate functions" do
      SQL.query!(TestRepo, "INSERT INTO test_types (real_col) VALUES (?)", [1.5])
      SQL.query!(TestRepo, "INSERT INTO test_types (real_col) VALUES (?)", [2.5])
      SQL.query!(TestRepo, "INSERT INTO test_types (real_col) VALUES (?)", [3.5])

      # SUM aggregate
      result = SQL.query!(TestRepo, "SELECT SUM(real_col) FROM test_types")
      assert [[sum]] = result.rows
      assert abs(sum - 7.5) < 0.001

      # AVG aggregate
      result = SQL.query!(TestRepo, "SELECT AVG(real_col) FROM test_types")
      assert [[avg]] = result.rows
      assert abs(avg - 2.5) < 0.001

      # COUNT still works
      result = SQL.query!(TestRepo, "SELECT COUNT(*) FROM test_types")
      assert [[3]] = result.rows
    end
  end

  describe "NULL/nil edge cases" do
    setup do
      SQL.query!(TestRepo, "DROP TABLE IF EXISTS test_types")

      SQL.query!(TestRepo, """
      CREATE TABLE test_types (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       int_col INTEGER,
       real_col REAL,
       text_col TEXT
      )
      """)

      on_exit(fn ->
        SQL.query!(TestRepo, "DROP TABLE IF EXISTS test_types")
      end)

      :ok
    end

    test "NULL in SUM aggregate returns NULL" do
      SQL.query!(TestRepo, "INSERT INTO test_types (int_col) VALUES (?)", [10])
      SQL.query!(TestRepo, "INSERT INTO test_types (int_col) VALUES (?)", [nil])
      SQL.query!(TestRepo, "INSERT INTO test_types (int_col) VALUES (?)", [20])

      result = SQL.query!(TestRepo, "SELECT SUM(int_col) FROM test_types")
      assert [[sum]] = result.rows
      # SUM ignores NULLs, so should be 30
      assert sum == 30
    end

    test "NULL in AVG aggregate is ignored" do
      SQL.query!(TestRepo, "INSERT INTO test_types (int_col) VALUES (?)", [10])
      SQL.query!(TestRepo, "INSERT INTO test_types (int_col) VALUES (?)", [nil])
      SQL.query!(TestRepo, "INSERT INTO test_types (int_col) VALUES (?)", [20])

      result = SQL.query!(TestRepo, "SELECT AVG(int_col) FROM test_types")
      assert [[avg]] = result.rows
      # AVG ignores NULLs, so should be 15 (30/2)
      assert avg == 15
    end

    test "COUNT with NULL values" do
      SQL.query!(TestRepo, "INSERT INTO test_types (int_col) VALUES (?)", [10])
      SQL.query!(TestRepo, "INSERT INTO test_types (int_col) VALUES (?)", [nil])
      SQL.query!(TestRepo, "INSERT INTO test_types (int_col) VALUES (?)", [20])

      # COUNT(*) counts all rows
      result = SQL.query!(TestRepo, "SELECT COUNT(*) FROM test_types")
      assert [[3]] = result.rows

      # COUNT(column) ignores NULLs
      result = SQL.query!(TestRepo, "SELECT COUNT(int_col) FROM test_types")
      assert [[2]] = result.rows
    end

    test "COALESCE with NULL values" do
      SQL.query!(TestRepo, "INSERT INTO test_types (int_col, text_col) VALUES (?, ?)", [
        nil,
        "default"
      ])

      SQL.query!(TestRepo, "INSERT INTO test_types (int_col, text_col) VALUES (?, ?)", [
        42,
        "value"
      ])

      result = SQL.query!(TestRepo, "SELECT COALESCE(int_col, 0) FROM test_types ORDER BY id")
      assert [[0], [42]] = result.rows
    end

    test "NULL in compound WHERE clause" do
      SQL.query!(TestRepo, "INSERT INTO test_types (int_col, text_col) VALUES (?, ?)", [10, "a"])
      SQL.query!(TestRepo, "INSERT INTO test_types (int_col, text_col) VALUES (?, ?)", [nil, "b"])
      SQL.query!(TestRepo, "INSERT INTO test_types (int_col, text_col) VALUES (?, ?)", [20, nil])

      # Find rows where int_col is NULL
      result = SQL.query!(TestRepo, "SELECT COUNT(*) FROM test_types WHERE int_col IS NULL")
      assert [[1]] = result.rows

      # Find rows where text_col is NOT NULL
      result = SQL.query!(TestRepo, "SELECT COUNT(*) FROM test_types WHERE text_col IS NOT NULL")
      assert [[2]] = result.rows

      # Compound condition with NULL
      result =
        SQL.query!(
          TestRepo,
          "SELECT COUNT(*) FROM test_types WHERE int_col IS NOT NULL AND text_col IS NOT NULL"
        )

      assert [[1]] = result.rows
    end

    test "NULL handling in CASE expressions" do
      SQL.query!(TestRepo, "INSERT INTO test_types (int_col) VALUES (?)", [10])
      SQL.query!(TestRepo, "INSERT INTO test_types (int_col) VALUES (?)", [nil])

      result =
        SQL.query!(
          TestRepo,
          "SELECT CASE WHEN int_col IS NULL THEN 'empty' ELSE 'has value' END FROM test_types ORDER BY id"
        )

      assert [["has value"], ["empty"]] = result.rows
    end

    test "NULL in ORDER BY" do
      SQL.query!(TestRepo, "INSERT INTO test_types (int_col, text_col) VALUES (?, ?)", [30, "c"])
      SQL.query!(TestRepo, "INSERT INTO test_types (int_col, text_col) VALUES (?, ?)", [nil, "a"])
      SQL.query!(TestRepo, "INSERT INTO test_types (int_col, text_col) VALUES (?, ?)", [10, "b"])

      # ORDER BY with NULLs (NULLs sort first in SQLite)
      result = SQL.query!(TestRepo, "SELECT int_col FROM test_types ORDER BY int_col")
      assert [[nil], [10], [30]] = result.rows
    end

    test "NULL with DISTINCT" do
      SQL.query!(TestRepo, "INSERT INTO test_types (int_col) VALUES (?)", [10])
      SQL.query!(TestRepo, "INSERT INTO test_types (int_col) VALUES (?)", [nil])
      SQL.query!(TestRepo, "INSERT INTO test_types (int_col) VALUES (?)", [10])
      SQL.query!(TestRepo, "INSERT INTO test_types (int_col) VALUES (?)", [nil])

      result = SQL.query!(TestRepo, "SELECT DISTINCT int_col FROM test_types ORDER BY int_col")
      assert [[nil], [10]] = result.rows
    end
  end

  describe "type coercion edge cases" do
    setup do
      SQL.query!(TestRepo, "DROP TABLE IF EXISTS test_types")

      SQL.query!(TestRepo, """
      CREATE TABLE test_types (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       int_col INTEGER,
       text_col TEXT,
       real_col REAL
      )
      """)

      on_exit(fn ->
        SQL.query!(TestRepo, "DROP TABLE IF EXISTS test_types")
      end)

      :ok
    end

    test "string that looks like number in text column" do
      result = SQL.query!(TestRepo, "INSERT INTO test_types (text_col) VALUES (?)", ["12345"])
      assert result.num_rows == 1

      result = SQL.query!(TestRepo, "SELECT text_col FROM test_types")
      assert [["12345"]] = result.rows
    end

    test "empty string vs NULL distinction" do
      SQL.query!(TestRepo, "INSERT INTO test_types (text_col) VALUES (?)", [""])
      SQL.query!(TestRepo, "INSERT INTO test_types (text_col) VALUES (?)", [nil])

      # Empty string is not NULL
      result = SQL.query!(TestRepo, "SELECT COUNT(*) FROM test_types WHERE text_col = ''")
      assert [[1]] = result.rows

      # NULL is NULL
      result = SQL.query!(TestRepo, "SELECT COUNT(*) FROM test_types WHERE text_col IS NULL")
      assert [[1]] = result.rows
    end

    test "zero vs NULL in numeric columns" do
      SQL.query!(TestRepo, "INSERT INTO test_types (int_col) VALUES (?)", [0])
      SQL.query!(TestRepo, "INSERT INTO test_types (int_col) VALUES (?)", [nil])

      # Zero is not NULL
      result = SQL.query!(TestRepo, "SELECT COUNT(*) FROM test_types WHERE int_col = ?", [0])
      assert [[1]] = result.rows

      # NULL is NULL
      result = SQL.query!(TestRepo, "SELECT COUNT(*) FROM test_types WHERE int_col IS NULL")
      assert [[1]] = result.rows
    end

    test "type affinity: integer stored in text column" do
      # SQLite has type affinity but is lenient
      result = SQL.query!(TestRepo, "INSERT INTO test_types (text_col) VALUES (?)", [123])
      assert result.num_rows == 1

      result = SQL.query!(TestRepo, "SELECT text_col FROM test_types")
      [[stored]] = result.rows
      # Integer stored in TEXT column is converted to string representation
      assert stored == "123"
    end

    test "float precision in arithmetic" do
      SQL.query!(TestRepo, "INSERT INTO test_types (real_col) VALUES (?)", [0.5])
      SQL.query!(TestRepo, "INSERT INTO test_types (real_col) VALUES (?)", [1.5])

      # Use integer-representable values to ensure deterministic results
      # 0.5 + 0.5 = 1.0, which equals 1.0 (match)
      # 1.5 + 0.5 = 2.0, which is > 1.0 (match)
      result =
        SQL.query!(
          TestRepo,
          "SELECT real_col FROM test_types WHERE real_col + ? >= ?",
          [0.5, 1.0]
        )

      # Exactly 2 rows match: 0.5 + 0.5 >= 1.0 and 1.5 + 0.5 >= 1.0
      assert length(result.rows) == 2
    end

    test "division by zero handling" do
      SQL.query!(TestRepo, "INSERT INTO test_types (int_col) VALUES (?)", [10])

      result = SQL.query!(TestRepo, "SELECT int_col / 0 FROM test_types")
      # SQLite returns NULL for division by zero
      assert [[nil]] = result.rows
    end

    test "string comparison vs numeric comparison" do
      SQL.query!(TestRepo, "INSERT INTO test_types (text_col) VALUES (?)", ["100"])
      SQL.query!(TestRepo, "INSERT INTO test_types (text_col) VALUES (?)", ["20"])

      # String comparison: "100" < "50" (true), "20" < "50" (true) → 2 matches
      result =
        SQL.query!(TestRepo, "SELECT COUNT(*) FROM test_types WHERE text_col < ?", ["50"])

      assert [[count]] = result.rows
      # Lexicographic: "100" < "50" (true), "20" < "50" (true) → 2 matches
      assert count == 2
    end
  end
end
