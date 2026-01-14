defmodule EctoLibSql.QueryEncodingTest do
  @moduledoc """
  Tests for query parameter encoding, especially temporal types and Decimal.

  These tests verify that Elixir types are properly converted to SQLite-compatible
  values before being sent to the Rust NIF. This is critical because Rustler cannot
  automatically serialise complex Elixir structs like DateTime, NaiveDateTime, etc.
  """
  use ExUnit.Case, async: true

  alias EctoLibSql.Query

  describe "encode/3 parameter conversion" do
    setup do
      query = %Query{statement: "INSERT INTO test VALUES (?)"}
      {:ok, query: query}
    end

    test "converts DateTime to ISO8601 string", %{query: query} do
      dt = ~U[2024-01-15 10:30:45.123456Z]
      params = [dt]

      encoded = DBConnection.Query.encode(query, params, [])

      assert [iso_string] = encoded
      assert is_binary(iso_string)
      assert iso_string == "2024-01-15T10:30:45.123456Z"
    end

    test "converts NaiveDateTime to ISO8601 string", %{query: query} do
      ndt = ~N[2024-01-15 10:30:45.123456]
      params = [ndt]

      encoded = DBConnection.Query.encode(query, params, [])

      assert [iso_string] = encoded
      assert is_binary(iso_string)
      assert iso_string == "2024-01-15T10:30:45.123456"
    end

    test "converts Date to ISO8601 string", %{query: query} do
      date = ~D[2024-01-15]
      params = [date]

      encoded = DBConnection.Query.encode(query, params, [])

      assert [iso_string] = encoded
      assert is_binary(iso_string)
      assert iso_string == "2024-01-15"
    end

    test "converts Time to ISO8601 string", %{query: query} do
      time = ~T[10:30:45.123456]
      params = [time]

      encoded = DBConnection.Query.encode(query, params, [])

      assert [iso_string] = encoded
      assert is_binary(iso_string)
      assert iso_string == "10:30:45.123456"
    end

    test "converts Decimal to string", %{query: query} do
      decimal = Decimal.new("123.456")
      params = [decimal]

      encoded = DBConnection.Query.encode(query, params, [])

      assert [string] = encoded
      assert is_binary(string)
      assert string == "123.456"
    end

    test "passes through nil values unchanged", %{query: query} do
      params = [nil]

      encoded = DBConnection.Query.encode(query, params, [])

      assert [nil] = encoded
    end

    test "passes through integer values unchanged", %{query: query} do
      params = [42, -100, 0]

      encoded = DBConnection.Query.encode(query, params, [])

      assert [42, -100, 0] = encoded
    end

    test "passes through float values unchanged", %{query: query} do
      params = [3.14, -2.5, 1.0]

      encoded = DBConnection.Query.encode(query, params, [])

      assert [3.14, -2.5, 1.0] = encoded
    end

    test "passes through string values unchanged", %{query: query} do
      params = ["hello", "", "with 'quotes'"]

      encoded = DBConnection.Query.encode(query, params, [])

      assert ["hello", "", "with 'quotes'"] = encoded
    end

    test "passes through binary values unchanged", %{query: query} do
      binary = <<1, 2, 3, 255>>
      params = [binary]

      encoded = DBConnection.Query.encode(query, params, [])

      assert [^binary] = encoded
    end

    test "converts boolean values to integers (SQLite representation)", %{query: query} do
      params = [true, false]

      encoded = DBConnection.Query.encode(query, params, [])

      assert [1, 0] = encoded
    end

    test "handles mixed parameter types", %{query: query} do
      params = [
        42,
        "hello",
        ~D[2024-01-15],
        ~T[10:30:45],
        nil,
        true,
        Decimal.new("99.99"),
        ~U[2024-01-15 10:30:45Z]
      ]

      encoded = DBConnection.Query.encode(query, params, [])

      assert [
               42,
               "hello",
               "2024-01-15",
               "10:30:45",
               nil,
               1,
               "99.99",
               "2024-01-15T10:30:45Z"
             ] = encoded
    end
  end

  describe "decode/3 result pass-through" do
    setup do
      query = %Query{statement: "SELECT * FROM test"}
      {:ok, query: query}
    end

    test "passes through result unchanged", %{query: query} do
      result = %EctoLibSql.Result{
        command: :select,
        columns: ["id", "name"],
        rows: [[1, "Alice"], [2, "Bob"]],
        num_rows: 2
      }

      decoded = DBConnection.Query.decode(query, result, [])

      assert decoded == result
    end

    test "preserves nil columns and rows for write operations", %{query: query} do
      result = %EctoLibSql.Result{
        command: :insert,
        columns: nil,
        rows: nil,
        num_rows: 1
      }

      decoded = DBConnection.Query.decode(query, result, [])

      assert decoded == result
      assert decoded.columns == nil
      assert decoded.rows == nil
    end

    test "preserves empty lists for queries with no results", %{query: query} do
      result = %EctoLibSql.Result{
        command: :select,
        columns: [],
        rows: [],
        num_rows: 0
      }

      decoded = DBConnection.Query.decode(query, result, [])

      assert decoded == result
      assert decoded.columns == []
      assert decoded.rows == []
    end
  end
end
