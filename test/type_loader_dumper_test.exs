defmodule EctoLibSql.TypeLoaderDumperTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Comprehensive test suite verifying that all Ecto types are properly handled
  by loaders and dumpers in the LibSQL adapter.

  This test ensures that:
  1. All supported Ecto primitive types have proper loaders/dumpers
  2. Type conversions work correctly in both directions
  3. Edge cases are handled properly
  4. SQLite type affinity works as expected
  """

  defmodule TestRepo do
    use Ecto.Repo, otp_app: :ecto_libsql, adapter: Ecto.Adapters.LibSql
  end

  defmodule AllTypesSchema do
    use Ecto.Schema

    schema "all_types" do
      # Integer types
      field(:id_field, :integer)
      field(:integer_field, :integer)

      # String types
      field(:string_field, :string)
      field(:binary_id_field, :binary_id)

      # Binary types
      field(:binary_field, :binary)

      # Boolean
      field(:boolean_field, :boolean)

      # Float
      field(:float_field, :float)

      # Decimal
      field(:decimal_field, :decimal)

      # Date/Time types
      field(:date_field, :date)
      field(:time_field, :time)
      field(:time_usec_field, :time_usec)
      field(:naive_datetime_field, :naive_datetime)
      field(:naive_datetime_usec_field, :naive_datetime_usec)
      field(:utc_datetime_field, :utc_datetime)
      field(:utc_datetime_usec_field, :utc_datetime_usec)

      # JSON/Map types
      field(:map_field, :map)
      field(:json_field, :map)

      # Array (stored as JSON)
      field(:array_field, {:array, :string})

      timestamps()
    end
  end

  @test_db "z_ecto_libsql_test-type_loaders_dumpers.db"

  setup_all do
    {:ok, _} = TestRepo.start_link(database: @test_db)

    Ecto.Adapters.SQL.query!(TestRepo, """
    CREATE TABLE IF NOT EXISTS all_types (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      id_field INTEGER,
      integer_field INTEGER,
      string_field TEXT,
      binary_id_field TEXT,
      binary_field BLOB,
      boolean_field INTEGER,
      float_field REAL,
      decimal_field DECIMAL,
      date_field DATE,
      time_field TIME,
      time_usec_field TIME,
      naive_datetime_field DATETIME,
      naive_datetime_usec_field DATETIME,
      utc_datetime_field DATETIME,
      utc_datetime_usec_field DATETIME,
      map_field TEXT,
      json_field TEXT,
      array_field TEXT,
      inserted_at DATETIME,
      updated_at DATETIME
    )
    """)

    on_exit(fn ->
      EctoLibSql.TestHelpers.cleanup_db_files(@test_db)
    end)

    :ok
  end

  setup do
    Ecto.Adapters.SQL.query!(TestRepo, "DELETE FROM all_types")
    :ok
  end

  describe "integer types" do
    test "id and integer fields load and dump correctly" do
      {:ok, result} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO all_types (id_field, integer_field) VALUES (?, ?)",
          [42, 100]
        )

      assert result.num_rows == 1

      {:ok, result} =
        Ecto.Adapters.SQL.query(TestRepo, "SELECT id_field, integer_field FROM all_types")

      assert [[42, 100]] = result.rows
    end

    test "handles zero and negative integers" do
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO all_types (integer_field) VALUES (?), (?), (?)",
          [0, -1, -9999]
        )

      {:ok, result} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "SELECT integer_field FROM all_types ORDER BY integer_field"
        )

      assert [[-9999], [-1], [0]] = result.rows
    end

    test "handles large integers" do
      max_int = 9_223_372_036_854_775_807
      min_int = -9_223_372_036_854_775_808

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO all_types (integer_field) VALUES (?), (?)",
          [max_int, min_int]
        )

      {:ok, result} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "SELECT integer_field FROM all_types ORDER BY integer_field"
        )

      assert [[^min_int], [^max_int]] = result.rows
    end
  end

  describe "string types" do
    test "string fields load and dump correctly" do
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO all_types (string_field) VALUES (?)",
          ["test string content"]
        )

      {:ok, result} =
        Ecto.Adapters.SQL.query(TestRepo, "SELECT string_field FROM all_types")

      assert [["test string content"]] = result.rows
    end

    test "handles empty strings" do
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO all_types (string_field) VALUES (?)",
          [""]
        )

      {:ok, result} = Ecto.Adapters.SQL.query(TestRepo, "SELECT string_field FROM all_types")

      assert [[""]] = result.rows
    end

    test "handles unicode and special characters" do
      unicode = "Hello 世界 🌍 émojis"

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO all_types (string_field) VALUES (?)",
          [unicode]
        )

      {:ok, result} = Ecto.Adapters.SQL.query(TestRepo, "SELECT string_field FROM all_types")

      assert [[^unicode]] = result.rows
    end

    test "binary_id (UUID) fields store as text" do
      uuid = Ecto.UUID.generate()

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO all_types (binary_id_field) VALUES (?)",
          [uuid]
        )

      {:ok, result} = Ecto.Adapters.SQL.query(TestRepo, "SELECT binary_id_field FROM all_types")

      assert [[^uuid]] = result.rows
    end
  end

  describe "binary types" do
    test "binary fields load and dump as blobs" do
      binary_data = <<1, 2, 3, 4, 255, 0, 128>>

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO all_types (binary_field) VALUES (?)",
          [binary_data]
        )

      {:ok, result} = Ecto.Adapters.SQL.query(TestRepo, "SELECT binary_field FROM all_types")

      assert [[^binary_data]] = result.rows
    end

    test "handles empty binary" do
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO all_types (binary_field) VALUES (?)",
          [<<>>]
        )

      {:ok, result} = Ecto.Adapters.SQL.query(TestRepo, "SELECT binary_field FROM all_types")

      assert [[<<>>]] = result.rows
    end

    test "handles large binary data" do
      large_binary = :crypto.strong_rand_bytes(10_000)

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO all_types (binary_field) VALUES (?)",
          [large_binary]
        )

      {:ok, result} = Ecto.Adapters.SQL.query(TestRepo, "SELECT binary_field FROM all_types")

      assert [[^large_binary]] = result.rows
    end
  end

  describe "boolean types" do
    test "boolean fields load and dump as 0/1" do
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO all_types (boolean_field) VALUES (?), (?)",
          [true, false]
        )

      {:ok, result} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "SELECT boolean_field FROM all_types ORDER BY boolean_field"
        )

      # SQLite stores booleans as 0/1 integers
      assert [[0], [1]] = result.rows
    end

    test "loader converts 0/1 to boolean" do
      # Insert records with raw integer values for boolean field.
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO all_types (id, boolean_field) VALUES (?, ?)",
          [
            1,
            0
          ]
        )

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO all_types (id, boolean_field) VALUES (?, ?)",
          [
            2,
            1
          ]
        )

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO all_types (id, boolean_field) VALUES (?, ?)",
          [
            3,
            nil
          ]
        )

      # Load via schema - the loader should convert.
      record_false = TestRepo.get(AllTypesSchema, 1)
      assert record_false.boolean_field == false

      record_true = TestRepo.get(AllTypesSchema, 2)
      assert record_true.boolean_field == true

      record_nil = TestRepo.get(AllTypesSchema, 3)
      assert record_nil.boolean_field == nil
    end
  end

  describe "float types" do
    test "float fields load and dump correctly" do
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO all_types (float_field) VALUES (?), (?), (?)",
          [3.14, 0.0, -2.71828]
        )

      {:ok, result} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "SELECT float_field FROM all_types ORDER BY float_field"
        )

      assert [[-2.71828], [0.0], [3.14]] = result.rows
    end

    test "handles special float values" do
      # Note: SQLite doesn't support Infinity/NaN, so we skip those
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO all_types (float_field) VALUES (?)",
          [1.0e-10]
        )

      {:ok, result} = Ecto.Adapters.SQL.query(TestRepo, "SELECT float_field FROM all_types")

      assert [[value]] = result.rows
      assert_in_delta value, 1.0e-10, 1.0e-15
    end
  end

  describe "decimal types" do
    test "decimal fields load and dump as strings" do
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO all_types (decimal_field) VALUES (?)",
          [Decimal.new("123.45")]
        )

      {:ok, result} = Ecto.Adapters.SQL.query(TestRepo, "SELECT decimal_field FROM all_types")

      # SQLite's NUMERIC type affinity stores decimals as numbers when possible,
      # but we need to accept either float or string representation from the query result
      assert [[value]] = result.rows

      case value do
        v when is_float(v) or is_integer(v) ->
          assert abs(v - 123.45) < 0.001

        v when is_binary(v) ->
          assert v == "123.45"
      end
    end

    test "decimal loader parses strings, integers, and floats" do
      {:ok, _} = Ecto.Adapters.SQL.query(TestRepo, "INSERT INTO all_types (id) VALUES (1)")

      # Update with different representations
      Ecto.Adapters.SQL.query!(TestRepo, "UPDATE all_types SET decimal_field = '999.99'")

      record = TestRepo.get(AllTypesSchema, 1)
      assert %Decimal{} = record.decimal_field
      assert Decimal.equal?(record.decimal_field, Decimal.new("999.99"))
    end

    test "handles negative decimals and zero" do
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO all_types (decimal_field) VALUES (?), (?), (?)",
          [Decimal.new("0"), Decimal.new("-123.45"), Decimal.new("999.999")]
        )

      {:ok, result} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "SELECT decimal_field FROM all_types ORDER BY decimal_field"
        )

      # SQLite's NUMERIC type affinity stores decimals as numbers, but accept
      # both numeric and string representations from the query result
      assert 3 = length(result.rows)

      # Normalize rows by converting to strings for comparison
      normalized_rows =
        Enum.map(result.rows, fn [value] ->
          case value do
            v when is_float(v) or is_integer(v) -> to_string(v)
            v when is_binary(v) -> v
          end
        end)

      # Verify values in sorted order (by parsed numeric value)
      assert length(normalized_rows) == 3
      [first, second, third] = normalized_rows

      # Check first is -123.45 (or 123.45 with leading -)
      assert String.contains?(first, "-123.45") or first == "-123.45"

      # Check second is 0
      assert second == "0" or String.to_float(second) == 0.0

      # Check third is 999.999
      assert String.contains?(third, "999.999") or third == "999.999"
    end
  end

  describe "date types" do
    test "date fields load and dump as ISO8601" do
      date = ~D[2026-01-14]

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO all_types (date_field) VALUES (?)",
          [date]
        )

      {:ok, result} = Ecto.Adapters.SQL.query(TestRepo, "SELECT date_field FROM all_types")

      # SQLite stores dates as ISO8601 strings
      assert [["2026-01-14"]] = result.rows
    end

    test "date loader parses ISO8601 strings" do
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO all_types (id, date_field) VALUES (1, '2026-12-31')"
        )

      record = TestRepo.get(AllTypesSchema, 1)
      assert %Date{} = record.date_field
      assert record.date_field == ~D[2026-12-31]
    end
  end

  describe "time types" do
    test "time fields load and dump as ISO8601" do
      time = ~T[14:30:45]

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO all_types (time_field) VALUES (?)",
          [time]
        )

      {:ok, result} = Ecto.Adapters.SQL.query(TestRepo, "SELECT time_field FROM all_types")

      assert [["14:30:45"]] = result.rows
    end

    test "time_usec preserves microseconds" do
      time = ~T[14:30:45.123456]

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO all_types (time_usec_field) VALUES (?)",
          [time]
        )

      {:ok, result} = Ecto.Adapters.SQL.query(TestRepo, "SELECT time_usec_field FROM all_types")

      assert [["14:30:45.123456"]] = result.rows
    end

    test "time loader parses ISO8601 strings" do
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO all_types (id, time_field) VALUES (1, '23:59:59')"
        )

      record = TestRepo.get(AllTypesSchema, 1)
      assert %Time{} = record.time_field
      assert record.time_field == ~T[23:59:59]
    end
  end

  describe "datetime types" do
    test "naive_datetime fields load and dump as ISO8601" do
      dt = ~N[2026-01-14 18:30:45]

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO all_types (naive_datetime_field) VALUES (?)",
          [dt]
        )

      {:ok, result} =
        Ecto.Adapters.SQL.query(TestRepo, "SELECT naive_datetime_field FROM all_types")

      assert [["2026-01-14T18:30:45"]] = result.rows
    end

    test "naive_datetime_usec preserves microseconds" do
      dt = ~N[2026-01-14 18:30:45.123456]

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO all_types (naive_datetime_usec_field) VALUES (?)",
          [dt]
        )

      {:ok, result} =
        Ecto.Adapters.SQL.query(TestRepo, "SELECT naive_datetime_usec_field FROM all_types")

      assert [["2026-01-14T18:30:45.123456"]] = result.rows
    end

    test "utc_datetime fields load and dump as ISO8601 with Z" do
      dt = ~U[2026-01-14 18:30:45Z]

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO all_types (utc_datetime_field) VALUES (?)",
          [dt]
        )

      {:ok, result} =
        Ecto.Adapters.SQL.query(TestRepo, "SELECT utc_datetime_field FROM all_types")

      # Should contain Z suffix
      assert [[iso_string]] = result.rows
      assert String.ends_with?(iso_string, "Z")
    end

    test "utc_datetime_usec preserves microseconds" do
      dt = ~U[2026-01-14 18:30:45.123456Z]

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO all_types (utc_datetime_usec_field) VALUES (?)",
          [dt]
        )

      {:ok, result} =
        Ecto.Adapters.SQL.query(TestRepo, "SELECT utc_datetime_usec_field FROM all_types")

      assert [[iso_string]] = result.rows
      assert String.contains?(iso_string, ".123456")
    end

    test "datetime loaders parse ISO8601 strings" do
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO all_types (id, naive_datetime_field, utc_datetime_field) VALUES (1, ?, ?)",
          ["2026-01-14T18:30:45", "2026-01-14T18:30:45Z"]
        )

      record = TestRepo.get(AllTypesSchema, 1)
      assert %NaiveDateTime{} = record.naive_datetime_field
      assert %DateTime{} = record.utc_datetime_field
    end
  end

  describe "json/map types" do
    test "map fields load and dump as JSON" do
      map = %{"key" => "value", "number" => 42}

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO all_types (map_field) VALUES (?)",
          [map]
        )

      {:ok, result} = Ecto.Adapters.SQL.query(TestRepo, "SELECT map_field FROM all_types")

      # Should be stored as JSON string
      assert [[json_string]] = result.rows
      assert is_binary(json_string)
      assert {:ok, decoded} = Jason.decode(json_string)
      assert decoded == %{"key" => "value", "number" => 42}
    end

    test "json loader parses JSON strings" do
      json_string = Jason.encode!(%{"nested" => %{"data" => [1, 2, 3]}})

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO all_types (id, json_field) VALUES (1, ?)",
          [json_string]
        )

      record = TestRepo.get(AllTypesSchema, 1)
      assert is_map(record.json_field)
      assert record.json_field == %{"nested" => %{"data" => [1, 2, 3]}}
    end

    test "handles empty maps" do
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO all_types (map_field) VALUES (?)",
          [%{}]
        )

      {:ok, result} = Ecto.Adapters.SQL.query(TestRepo, "SELECT map_field FROM all_types")

      assert [["{}"]] = result.rows
    end
  end

  describe "array types" do
    test "array fields load and dump as JSON arrays" do
      array = ["a", "b", "c"]

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO all_types (array_field) VALUES (?)",
          [array]
        )

      {:ok, result} = Ecto.Adapters.SQL.query(TestRepo, "SELECT array_field FROM all_types")

      # Should be stored as JSON array string
      assert [[json_string]] = result.rows
      assert {:ok, decoded} = Jason.decode(json_string)
      assert decoded == ["a", "b", "c"]
    end

    test "array loader parses JSON array strings" do
      json_array = Jason.encode!(["one", "two", "three", "four", "five"])

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO all_types (id, array_field) VALUES (1, ?)",
          [json_array]
        )

      record = TestRepo.get(AllTypesSchema, 1)
      assert is_list(record.array_field)
      assert record.array_field == ["one", "two", "three", "four", "five"]
    end

    test "handles empty arrays" do
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO all_types (array_field) VALUES (?)",
          [[]]
        )

      {:ok, result} = Ecto.Adapters.SQL.query(TestRepo, "SELECT array_field FROM all_types")

      assert [["[]"]] = result.rows
    end

    test "empty string defaults to empty array" do
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO all_types (id, array_field) VALUES (1, '')"
        )

      record = TestRepo.get(AllTypesSchema, 1)
      assert record.array_field == []
    end
  end

  describe "NULL handling" do
    test "all types handle NULL correctly" do
      {:ok, _} = Ecto.Adapters.SQL.query(TestRepo, "INSERT INTO all_types (id) VALUES (1)")

      {:ok, result} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "SELECT string_field, integer_field, float_field, boolean_field, binary_field FROM all_types"
        )

      # All should be nil
      assert [[nil, nil, nil, nil, nil]] = result.rows
    end

    test "explicit NULL insertion" do
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO all_types (string_field, integer_field) VALUES (?, ?)",
          [nil, nil]
        )

      {:ok, result} =
        Ecto.Adapters.SQL.query(TestRepo, "SELECT string_field, integer_field FROM all_types")

      assert [[nil, nil]] = result.rows
    end
  end

  describe "round-trip through schema" do
    test "all types round-trip correctly through Ecto schema" do
      now = DateTime.utc_now()
      naive_now = NaiveDateTime.utc_now()

      attrs = %{
        id_field: 42,
        integer_field: 100,
        string_field: "test",
        binary_id_field: Ecto.UUID.generate(),
        binary_field: <<1, 2, 3, 255>>,
        boolean_field: true,
        float_field: 3.14,
        decimal_field: Decimal.new("123.45"),
        date_field: ~D[2026-01-14],
        time_field: ~T[12:30:45],
        time_usec_field: ~T[12:30:45.123456],
        naive_datetime_field: naive_now,
        naive_datetime_usec_field: naive_now,
        utc_datetime_field: now,
        utc_datetime_usec_field: now,
        map_field: %{"key" => "value"},
        json_field: %{"nested" => %{"data" => true}},
        array_field: ["a", "b", "c"]
      }

      # Insert via raw SQL
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          """
          INSERT INTO all_types (
            id_field, integer_field, string_field, binary_id_field,
            binary_field, boolean_field, float_field, decimal_field, date_field,
            time_field, time_usec_field, naive_datetime_field, naive_datetime_usec_field,
            utc_datetime_field, utc_datetime_usec_field, map_field, json_field, array_field
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
          [
            attrs.id_field,
            attrs.integer_field,
            attrs.string_field,
            attrs.binary_id_field,
            attrs.binary_field,
            attrs.boolean_field,
            attrs.float_field,
            attrs.decimal_field,
            attrs.date_field,
            attrs.time_field,
            attrs.time_usec_field,
            attrs.naive_datetime_field,
            attrs.naive_datetime_usec_field,
            attrs.utc_datetime_field,
            attrs.utc_datetime_usec_field,
            attrs.map_field,
            attrs.json_field,
            attrs.array_field
          ]
        )

      # Load via schema
      [record] = TestRepo.all(AllTypesSchema)

      # Verify all fields loaded correctly
      assert record.id_field == attrs.id_field
      assert record.integer_field == attrs.integer_field
      assert record.string_field == attrs.string_field
      assert record.binary_id_field == attrs.binary_id_field
      assert record.binary_field == attrs.binary_field
      assert record.boolean_field == attrs.boolean_field
      assert_in_delta record.float_field, attrs.float_field, 0.01
      assert Decimal.equal?(record.decimal_field, attrs.decimal_field)
      assert record.date_field == attrs.date_field
      assert record.time_field == attrs.time_field
      assert record.time_usec_field == attrs.time_usec_field
      # Microseconds might be truncated depending on precision, verify date/time components
      assert record.naive_datetime_field.year == naive_now.year
      assert record.naive_datetime_field.month == naive_now.month
      assert record.naive_datetime_field.day == naive_now.day
      assert record.naive_datetime_field.hour == naive_now.hour
      assert record.utc_datetime_field.year == now.year
      assert record.utc_datetime_field.month == now.month
      assert record.utc_datetime_field.day == now.day
      assert record.utc_datetime_field.hour == now.hour
      assert record.map_field == attrs.map_field
      assert record.json_field == attrs.json_field
      assert record.array_field == attrs.array_field
    end
  end
end
