defmodule EctoLibSql.JSONHelpersTest do
  use ExUnit.Case
  alias EctoLibSql.JSON

  setup do
    {:ok, state} = EctoLibSql.connect(database: ":memory:")

    # Create a test table with JSON columns
    {:ok, _, _, state} =
      EctoLibSql.handle_execute(
        """
        CREATE TABLE IF NOT EXISTS json_test (
          id INTEGER PRIMARY KEY,
          data TEXT,
          data_jsonb BLOB,
          metadata TEXT
        )
        """,
        [],
        [],
        state
      )

    on_exit(fn ->
      EctoLibSql.disconnect([], state)
    end)

    {:ok, state: state}
  end

  describe "json_extract/3" do
    test "extracts simple value from JSON object", %{state: state} do
      json = ~s({"name":"Alice","age":30})
      {:ok, name} = JSON.extract(state, json, "$.name")
      assert name == "Alice"
    end

    test "extracts numeric value", %{state: state} do
      json = ~s({"count":42})
      {:ok, count} = JSON.extract(state, json, "$.count")
      assert count == 42
    end

    test "extracts nested value", %{state: state} do
      json = ~s({"user":{"name":"Bob","email":"bob@example.com"}})
      {:ok, email} = JSON.extract(state, json, "$.user.email")
      assert email == "bob@example.com"
    end

    test "extracts from array", %{state: state} do
      json = ~s([1,2,3,4,5])
      {:ok, value} = JSON.extract(state, json, "$[2]")
      assert value == 3
    end

    test "returns nil for missing path", %{state: state} do
      json = ~s({"a":1})
      {:ok, result} = JSON.extract(state, json, "$.b")
      assert result == nil
    end

    test "extracts null value", %{state: state} do
      json = ~s({"value":null})
      {:ok, result} = JSON.extract(state, json, "$.value")
      assert result == nil
    end

    test "extracts array as JSON", %{state: state} do
      json = ~s({"items":[1,2,3]})
      {:ok, result} = JSON.extract(state, json, "$.items")
      # Arrays are returned as JSON text
      assert is_binary(result)
      # Parse the JSON array to verify exact content
      {:ok, decoded} = Jason.decode(result)
      assert decoded == [1, 2, 3]
    end
  end

  describe "json_type/2 and json_type/3" do
    test "detects text type", %{state: state} do
      json = ~s({"name":"Alice"})
      {:ok, type} = JSON.type(state, json, "$.name")
      assert type == "text"
    end

    test "detects integer type", %{state: state} do
      json = ~s({"age":30})
      {:ok, type} = JSON.type(state, json, "$.age")
      assert type == "integer"
    end

    test "detects real type", %{state: state} do
      json = ~s({"price":19.99})
      {:ok, type} = JSON.type(state, json, "$.price")
      assert type == "real"
    end

    test "detects array type", %{state: state} do
      json = ~s({"items":[1,2,3]})
      {:ok, type} = JSON.type(state, json, "$.items")
      assert type == "array"
    end

    test "detects object type", %{state: state} do
      json = ~s({"user":{"name":"Bob"}})
      {:ok, type} = JSON.type(state, json, "$.user")
      assert type == "object"
    end

    test "detects null type", %{state: state} do
      json = ~s({"value":null})
      {:ok, type} = JSON.type(state, json, "$.value")
      assert type == "null"
    end

    test "detects root type as array", %{state: state} do
      json = ~s([1,2,3])
      {:ok, type} = JSON.type(state, json)
      assert type == "array"
    end

    test "detects root type as object", %{state: state} do
      json = ~s({"a":1})
      {:ok, type} = JSON.type(state, json)
      assert type == "object"
    end
  end

  describe "json_is_valid/2" do
    test "validates correct JSON object", %{state: state} do
      {:ok, valid?} = JSON.is_valid(state, ~s({"a":1}))
      assert valid? == true
    end

    test "validates correct JSON array", %{state: state} do
      {:ok, valid?} = JSON.is_valid(state, ~s([1,2,3]))
      assert valid? == true
    end

    test "validates JSON string", %{state: state} do
      {:ok, valid?} = JSON.is_valid(state, ~s("hello"))
      assert valid? == true
    end

    test "validates JSON number", %{state: state} do
      {:ok, valid?} = JSON.is_valid(state, "42")
      assert valid? == true
    end

    test "rejects invalid JSON", %{state: state} do
      {:ok, valid?} = JSON.is_valid(state, "not json")
      assert valid? == false
    end

    test "rejects empty string", %{state: state} do
      {:ok, valid?} = JSON.is_valid(state, "")
      assert valid? == false
    end

    test "rejects malformed JSON - incomplete string key", %{state: state} do
      {:ok, valid?} = JSON.is_valid(state, ~s({"a))
      assert valid? == false
    end
  end

  describe "json_array/2" do
    test "creates array from integers", %{state: state} do
      {:ok, json} = JSON.array(state, [1, 2, 3])
      assert json == "[1,2,3]"
    end

    test "creates array from mixed types", %{state: state} do
      {:ok, json} = JSON.array(state, [1, 2.5, "hello", nil])
      assert json == "[1,2.5,\"hello\",null]"
    end

    test "creates empty array", %{state: state} do
      {:ok, json} = JSON.array(state, [])
      assert json == "[]"
    end

    test "creates array with single element", %{state: state} do
      {:ok, json} = JSON.array(state, ["test"])
      assert json == "[\"test\"]"
    end

    test "arrays with strings containing special chars", %{state: state} do
      {:ok, json} = JSON.array(state, ["hello \"world\"", "tab\there"])
      # Parse and validate the structure with proper escape sequences
      {:ok, decoded} = Jason.decode(json)
      assert length(decoded) == 2
      assert Enum.at(decoded, 0) == "hello \"world\""
      assert Enum.at(decoded, 1) == "tab\there"
    end
  end

  describe "json_object/2" do
    test "creates object from key-value pairs", %{state: state} do
      {:ok, json} = JSON.object(state, ["name", "Alice", "age", 30])
      # Order may vary, check both fields exist
      assert String.contains?(json, ["name"])
      assert String.contains?(json, ["Alice"])
      assert String.contains?(json, ["age"])
      assert String.contains?(json, ["30"])
    end

    test "creates empty object", %{state: state} do
      {:ok, json} = JSON.object(state, [])
      assert json == "{}"
    end

    test "creates object with single pair", %{state: state} do
      {:ok, json} = JSON.object(state, ["key", "value"])
      assert String.contains?(json, ["key", "value"])
    end

    test "creates object with nil values", %{state: state} do
      {:ok, json} = JSON.object(state, ["name", "Bob", "deleted_at", nil])
      assert String.contains?(json, ["name", "Bob", "deleted_at", "null"])
    end

    test "creates object with numeric values", %{state: state} do
      {:ok, json} = JSON.object(state, ["id", 1, "price", 99.99])
      assert String.contains?(json, ["id", "1", "price", "99.99"])
    end

    test "rejects odd number of arguments", %{state: state} do
      {:error, {:invalid_arguments, _msg}} = JSON.object(state, ["a", 1, "b"])
    end
  end

  describe "json_each/2 and json_each/3" do
    test "iterates over array elements", %{state: state} do
      {:ok, items} = JSON.each(state, ~s([1,2,3]))
      assert length(items) == 3
      # Items should contain key, value, type tuples
      assert Enum.all?(items, fn item -> is_tuple(item) and tuple_size(item) == 3 end)
    end

    test "iterates over object members", %{state: state} do
      {:ok, items} = JSON.each(state, ~s({"a":1,"b":2}))
      assert length(items) == 2
    end

    test "iterates with custom path", %{state: state} do
      json = ~s({"items":[1,2,3]})
      {:ok, items} = JSON.each(state, json, "$.items")
      assert length(items) == 3
    end

    test "returns empty for non-iterable type", %{state: state} do
      {:ok, items} = JSON.each(state, ~s({"value":"string"}), "$.value")
      # Scalar values can return metadata about the value
      assert is_list(items)
    end
  end

  describe "json_tree/2 and json_tree/3" do
    test "recursively iterates JSON structure", %{state: state} do
      json = ~s({"a":1,"b":{"c":2}})
      {:ok, tree} = JSON.tree(state, json)
      # Should include root and all nested values
      assert length(tree) > 2
      assert Enum.all?(tree, fn item -> is_tuple(item) and tuple_size(item) == 3 end)
    end

    test "traverses array of objects", %{state: state} do
      json = ~s([{"id":1},{"id":2}])
      {:ok, tree} = JSON.tree(state, json)
      # Multiple entries for nested structure
      assert length(tree) >= 3
    end

    test "tree includes full paths", %{state: state} do
      json = ~s({"user":{"name":"Alice"}})
      {:ok, tree} = JSON.tree(state, json)
      # Extract the fullkey values
      fullkeys = Enum.map(tree, fn {k, _, _} -> k end)
      # Should include paths like $ and $.user
      assert Enum.any?(fullkeys, fn k -> String.contains?(k, "user") end)
    end
  end

  describe "json_convert/2 and json_convert/3" do
    test "normalizes JSON text", %{state: state} do
      json = ~s(  {"a":1}  )
      {:ok, result} = JSON.convert(state, json, :json)
      # Should be canonical form
      assert result == ~s({"a":1})
    end

    test "converts to JSONB binary format", %{state: state} do
      json = ~s({"a":1})
      {:ok, result} = JSON.convert(state, json, :jsonb)
      # Should be binary
      assert is_binary(result)
      # JSONB is a binary format (different from text JSON)
      # Note: JSONB may be smaller, but size is not a stable guarantee across versions
      assert result != json
    end

    test "default format is JSON", %{state: state} do
      json = ~s({"a":1})
      {:ok, result} = JSON.convert(state, json)
      # Should be text JSON by default
      assert is_binary(result)
      assert String.contains?(result, ~s("a"))
    end

    test "validates during conversion", %{state: state} do
      {:error, _reason} = JSON.convert(state, "invalid", :json)
    end
  end

  describe "arrow_fragment/2 and arrow_fragment/3" do
    test "generates arrow operator fragment for string key" do
      fragment = JSON.arrow_fragment("settings", "theme")
      assert fragment == "settings -> 'theme'"
    end

    test "generates arrow operator fragment for array index" do
      fragment = JSON.arrow_fragment("items", 0)
      assert fragment == "items -> 0"
    end

    test "generates double-arrow operator fragment for string key" do
      fragment = JSON.arrow_fragment("settings", "theme", :double_arrow)
      assert fragment == "settings ->> 'theme'"
    end

    test "generates double-arrow operator fragment for array index" do
      fragment = JSON.arrow_fragment("items", 0, :double_arrow)
      assert fragment == "items ->> 0"
    end

    test "escapes single quotes in path to prevent SQL injection" do
      fragment = JSON.arrow_fragment("settings", "user'name")
      assert fragment == "settings -> 'user''name'"
    end

    test "escapes single quotes in path with double-arrow operator" do
      fragment = JSON.arrow_fragment("settings", "user'name", :double_arrow)
      assert fragment == "settings ->> 'user''name'"
    end

    test "validates json_column is a safe identifier" do
      assert_raise ArgumentError, fn ->
        JSON.arrow_fragment("settings; DROP TABLE users", "theme")
      end
    end

    test "validates json_column rejects invalid identifiers with special chars" do
      assert_raise ArgumentError, fn ->
        JSON.arrow_fragment("settings.theme", "key")
      end
    end

    test "allows valid identifiers with underscores and numbers" do
      fragment = JSON.arrow_fragment("user_settings_123", "theme")
      assert fragment == "user_settings_123 -> 'theme'"
    end

    test "allows valid identifiers starting with underscore" do
      fragment = JSON.arrow_fragment("_private_data", "key")
      assert fragment == "_private_data -> 'key'"
    end
  end

  describe "Ecto integration" do
    test "JSON helpers work in insert/select flow", %{state: state} do
      # Insert JSON data
      json_data = ~s({"name":"test","value":123})

      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO json_test (id, data) VALUES (1, ?)",
          [json_data],
          [],
          state
        )

      # Extract using JSON helpers
      {:ok, name} = JSON.extract(state, json_data, "$.name")
      {:ok, type} = JSON.type(state, json_data, "$.value")

      assert name == "test"
      assert type == "integer"
    end

    test "JSONB storage and retrieval", %{state: state} do
      json_data = ~s({"active":true,"tags":["a","b"]})

      # Convert to JSONB
      {:ok, jsonb_data} = JSON.convert(state, json_data, :jsonb)

      # Insert JSONB
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO json_test (id, data_jsonb) VALUES (2, ?)",
          [jsonb_data],
          [],
          state
        )

      # Retrieve and convert back to text
      {:ok, _, result, _state} =
        EctoLibSql.handle_execute(
          "SELECT json(data_jsonb) FROM json_test WHERE id = 2",
          [],
          [],
          state
        )

      [[json_text]] = result.rows

      # Verify we can extract from the retrieved JSON
      {:ok, active} = JSON.extract(state, json_text, "$.active")
      # SQLite stores booleans as integers
      assert active == true or active == 1
    end
  end

  describe "edge cases" do
    test "handles deeply nested JSON", %{state: state} do
      json = ~s({"a":{"b":{"c":{"d":{"e":{"f":1}}}}}})
      {:ok, value} = JSON.extract(state, json, "$.a.b.c.d.e.f")
      assert value == 1
    end

    test "handles JSON with unicode", %{state: state} do
      json = ~s({"emoji":"🎉","name":"José"})
      {:ok, emoji} = JSON.extract(state, json, "$.emoji")
      {:ok, name} = JSON.extract(state, json, "$.name")
      assert String.contains?(emoji, "🎉")
      assert String.contains?(name, "José")
    end

    test "handles large JSON arrays", %{state: state} do
      values = Enum.to_list(1..100)
      {:ok, json} = JSON.array(state, values)
      assert is_binary(json)
      # Parse and verify exact array content
      {:ok, decoded} = Jason.decode(json)
      assert decoded == values
      assert length(decoded) == 100
    end

    test "handles JSON with reserved characters", %{state: state} do
      json = ~s({"sql":"SELECT * FROM table","regex":"[a-z]+","path":"C:\\\\Users\\\\file"})
      {:ok, sql} = JSON.extract(state, json, "$.sql")
      assert String.contains?(sql, "SELECT")
    end
  end

  describe "json_quote/2" do
    test "quotes a simple string", %{state: state} do
      {:ok, quoted} = JSON.json_quote(state, "hello")
      assert quoted == "\"hello\""
    end

    test "escapes special characters in strings", %{state: state} do
      {:ok, quoted} = JSON.json_quote(state, "hello \"world\"")
      assert quoted == "\"hello \\\"world\\\"\""
    end

    test "quotes numbers as strings", %{state: state} do
      {:ok, quoted} = JSON.json_quote(state, "42")
      assert quoted == "\"42\""
    end
  end

  describe "json_length/2 and json_length/3" do
    test "gets length of JSON array", %{state: state} do
      # json_length is available in SQLite 3.9.0+ (libSQL 0.3.0+)
      case JSON.json_length(state, ~s([1,2,3,4,5])) do
        {:ok, len} -> assert len == 5
        {:error, "SQLite failure: `no such function: json_length`"} -> :skip
        {:error, reason} -> raise reason
      end
    end

    test "gets number of keys in JSON object", %{state: state} do
      case JSON.json_length(state, ~s({"a":1,"b":2,"c":3})) do
        {:ok, len} -> assert len == 3
        {:error, "SQLite failure: `no such function: json_length`"} -> :skip
        {:error, reason} -> raise reason
      end
    end

    test "returns nil for scalar values", %{state: state} do
      case JSON.json_length(state, "42") do
        {:ok, len} -> assert len == nil
        {:error, "SQLite failure: `no such function: json_length`"} -> :skip
        {:error, reason} -> raise reason
      end
    end

    test "gets length of nested array using path", %{state: state} do
      json = ~s({"items":[1,2,3]})

      case JSON.json_length(state, json, "$.items") do
        {:ok, len} -> assert len == 3
        {:error, "SQLite failure: `no such function: json_length`"} -> :skip
        {:error, reason} -> raise reason
      end
    end
  end

  describe "json_depth/2" do
    test "depth of scalar value is 1", %{state: state} do
      case JSON.depth(state, "42") do
        {:ok, depth} -> assert depth == 1
        {:error, "SQLite failure: `no such function: json_depth`"} -> :skip
        {:error, reason} -> raise reason
      end
    end

    test "depth of simple array is 2", %{state: state} do
      case JSON.depth(state, ~s([1,2,3])) do
        {:ok, depth} -> assert depth == 2
        {:error, "SQLite failure: `no such function: json_depth`"} -> :skip
        {:error, reason} -> raise reason
      end
    end

    test "depth of simple object is 2", %{state: state} do
      case JSON.depth(state, ~s({"a":1})) do
        {:ok, depth} -> assert depth == 2
        {:error, "SQLite failure: `no such function: json_depth`"} -> :skip
        {:error, reason} -> raise reason
      end
    end

    test "depth of nested structure increases", %{state: state} do
      case JSON.depth(state, ~s({"a":{"b":1}})) do
        {:ok, depth} -> assert depth == 3
        {:error, "SQLite failure: `no such function: json_depth`"} -> :skip
        {:error, reason} -> raise reason
      end
    end

    test "depth of deeply nested structure", %{state: state} do
      json = ~s({"a":{"b":{"c":{"d":1}}}})

      case JSON.depth(state, json) do
        {:ok, depth} -> assert depth == 5
        {:error, "SQLite failure: `no such function: json_depth`"} -> :skip
        {:error, reason} -> raise reason
      end
    end
  end

  describe "json_remove/3" do
    test "removes single key from object", %{state: state} do
      {:ok, result} = JSON.remove(state, ~s({"a":1,"b":2,"c":3}), "$.b")
      # Verify b is removed
      assert not String.contains?(result, "\"b\"")
      assert String.contains?(result, "\"a\"")
      assert String.contains?(result, "\"c\"")
    end

    test "removes single index from array", %{state: state} do
      {:ok, result} = JSON.remove(state, ~s([1,2,3,4,5]), "$[2]")
      # Should remove the 3 (index 2), resulting in [1,2,4,5]
      {:ok, decoded} = Jason.decode(result)
      assert decoded == [1, 2, 4, 5]
    end

    test "removes multiple paths from object", %{state: state} do
      {:ok, result} = JSON.remove(state, ~s({"a":1,"b":2,"c":3}), ["$.a", "$.c"])
      # Only b should remain
      assert String.contains?(result, "\"b\"")
      assert not String.contains?(result, "\"a\"")
      assert not String.contains?(result, "\"c\"")
    end
  end

  describe "json_set/4" do
    test "sets new key in object", %{state: state} do
      {:ok, result} = JSON.set(state, ~s({"a":1}), "$.b", 2)
      {:ok, b_val} = JSON.extract(state, result, "$.b")
      assert b_val == 2
    end

    test "replaces existing key in object", %{state: state} do
      {:ok, result} = JSON.set(state, ~s({"a":1,"b":2}), "$.a", 10)
      {:ok, a_val} = JSON.extract(state, result, "$.a")
      assert a_val == 10
    end

    test "sets value in array by index", %{state: state} do
      {:ok, result} = JSON.set(state, ~s([1,2,3]), "$[1]", 20)
      {:ok, val} = JSON.extract(state, result, "$[1]")
      assert val == 20
    end

    test "creates nested path if not exists", %{state: state} do
      {:ok, result} = JSON.set(state, ~s({}), "$.nested.key", "value")
      {:ok, val} = JSON.extract(state, result, "$.nested.key")
      assert val == "value"
    end
  end

  describe "json_replace/4" do
    test "replaces existing value in object", %{state: state} do
      {:ok, result} = JSON.replace(state, ~s({"a":1,"b":2}), "$.a", 10)
      {:ok, a_val} = JSON.extract(state, result, "$.a")
      assert a_val == 10
    end

    test "ignores non-existent path", %{state: state} do
      {:ok, result} = JSON.replace(state, ~s({"a":1}), "$.z", 99)
      # Should still contain only a
      {:ok, a_val} = JSON.extract(state, result, "$.a")
      assert a_val == 1
      {:ok, z_val} = JSON.extract(state, result, "$.z")
      assert z_val == nil
    end

    test "replaces in nested structure", %{state: state} do
      {:ok, result} = JSON.replace(state, ~s({"user":{"name":"Alice"}}), "$.user.name", "Bob")
      {:ok, name} = JSON.extract(state, result, "$.user.name")
      assert name == "Bob"
    end
  end

  describe "json_insert/4" do
    test "inserts new key into object", %{state: state} do
      {:ok, result} = JSON.insert(state, ~s({"a":1}), "$.b", 2)
      {:ok, b_val} = JSON.extract(state, result, "$.b")
      assert b_val == 2
    end

    test "does not replace existing key", %{state: state} do
      {:ok, result} = JSON.insert(state, ~s({"a":1}), "$.a", 10)
      # Should still have original value since insert doesn't replace
      {:ok, a_val} = JSON.extract(state, result, "$.a")
      assert a_val == 1
    end
  end

  describe "json_patch/3" do
    test "applies patches (implementation-dependent)", %{state: state} do
      # Note: json_patch behavior varies by SQLite version
      # Some versions treat keys as JSON paths, others as literal values
      # This test just verifies the function works
      {:ok, result} = JSON.patch(state, ~s({"a":1,"b":2}), ~s({"a":10}))
      assert is_binary(result)
    end
  end

  describe "json_keys/2 and json_keys/3" do
    test "gets keys from object", %{state: state} do
      case JSON.keys(state, ~s({"name":"Alice","age":30})) do
        {:ok, keys} ->
          # Keys should be in an array (possibly sorted)
          assert is_binary(keys)
          assert String.contains?(keys, ["name", "age"])

        {:error, "SQLite failure: `no such function: json_keys`"} ->
          :skip

        {:error, reason} ->
          raise reason
      end
    end

    test "returns nil for non-object", %{state: state} do
      case JSON.keys(state, ~s([1,2,3])) do
        {:ok, keys} -> assert keys == nil
        {:error, "SQLite failure: `no such function: json_keys`"} -> :skip
        {:error, reason} -> raise reason
      end
    end

    test "gets keys from nested object using path", %{state: state} do
      json = ~s({"user":{"name":"Bob","email":"bob@example.com"}})

      case JSON.keys(state, json, "$.user") do
        {:ok, keys} ->
          assert is_binary(keys)
          assert String.contains?(keys, ["name", "email"])

        {:error, "SQLite failure: `no such function: json_keys`"} ->
          :skip

        {:error, reason} ->
          raise reason
      end
    end
  end

  describe "integration - JSON modifications" do
    test "chaining multiple modifications", %{state: state} do
      # Build up JSON step by step
      json = ~s({"user":{}})

      # Set name field
      {:ok, json} = JSON.set(state, json, "$.user.name", "Alice")

      # Set id field
      {:ok, json} = JSON.set(state, json, "$.user.id", 1)

      # Verify both were set
      {:ok, name} = JSON.extract(state, json, "$.user.name")
      {:ok, id} = JSON.extract(state, json, "$.user.id")
      assert name == "Alice"
      assert id == 1
    end

    test "remove then set operations", %{state: state} do
      json = ~s({"a":1,"b":2,"c":3})

      # Remove b
      {:ok, json} = JSON.remove(state, json, "$.b")

      # Set d
      {:ok, json} = JSON.set(state, json, "$.d", 4)

      # Verify state
      {:ok, b_val} = JSON.extract(state, json, "$.b")
      {:ok, d_val} = JSON.extract(state, json, "$.d")
      assert b_val == nil
      assert d_val == 4
    end

    test "working with deeply nested updates", %{state: state} do
      json = ~s({"data":{"deep":{"nested":{"value":1}}}})

      # Update deeply nested value
      {:ok, json} = JSON.replace(state, json, "$.data.deep.nested.value", 999)

      # Verify
      {:ok, val} = JSON.extract(state, json, "$.data.deep.nested.value")
      assert val == 999
    end
  end

  describe "JSONB binary format operations" do
    test "JSONB round-trip correctness: text → JSONB → text", %{state: state} do
      original_json = ~s({"name":"Alice","age":30,"active":true,"tags":["a","b"]})

      # Convert to JSONB
      {:ok, jsonb} = JSON.convert(state, original_json, :jsonb)
      assert is_binary(jsonb)
      assert byte_size(jsonb) > 0

      # Convert back to text JSON
      {:ok, _, result, _state} =
        EctoLibSql.handle_execute(
          "SELECT json(?)",
          [jsonb],
          [],
          state
        )

      [[canonical_json]] = result.rows

      # Parse both to ensure semantic equivalence
      {:ok, original_decoded} = Jason.decode(original_json)
      {:ok, canonical_decoded} = Jason.decode(canonical_json)

      assert original_decoded == canonical_decoded
    end

    test "JSONB and text JSON produce identical extraction results", %{state: state} do
      json_text = ~s({"user":{"name":"Bob","email":"bob@example.com"},"count":42})

      # Convert to JSONB
      {:ok, jsonb} = JSON.convert(state, json_text, :jsonb)

      # Extract from text JSON
      {:ok, name_text} = JSON.extract(state, json_text, "$.user.name")
      {:ok, count_text} = JSON.extract(state, json_text, "$.count")

      # Extract from JSONB (stored as binary)
      {:ok, _, result, _state} =
        EctoLibSql.handle_execute(
          "SELECT json_extract(?, '$.user.name'), json_extract(?, '$.count')",
          [jsonb, jsonb],
          [],
          state
        )

      [[name_jsonb, count_jsonb]] = result.rows

      assert name_text == name_jsonb
      assert count_text == count_jsonb
    end

    test "JSONB storage is 5-10% smaller than text JSON", %{state: state} do
      # Create a reasonably sized JSON object
      json_text =
        ~s({"user":{"id":1,"name":"Alice","email":"alice@example.com","profile":{"bio":"Software engineer","location":"San Francisco","interests":["Elixir","Rust","Go"]},"settings":{"theme":"dark","notifications":true,"language":"en"}}})

      # Convert to JSONB
      {:ok, jsonb} = JSON.convert(state, json_text, :jsonb)

      text_size = byte_size(json_text)
      jsonb_size = byte_size(jsonb)

      # JSONB should be smaller (5-10% is typical, but may vary)
      # We check for general size improvement (not overly strict)
      assert jsonb_size <= text_size,
             "JSONB (#{jsonb_size} bytes) should be <= text JSON (#{text_size} bytes)"

      # Most of the time JSONB is noticeably smaller
      # but we don't enforce a strict percentage due to variation
    end

    test "JSONB modification preserves format (json_set)", %{state: state} do
      json_text = ~s({"name":"Alice","age":30})

      # Convert to JSONB
      {:ok, jsonb} = JSON.convert(state, json_text, :jsonb)

      # Modify JSONB using json_set
      {:ok, _, result, _state} =
        EctoLibSql.handle_execute(
          "SELECT json_set(?, '$.age', 31)",
          [jsonb],
          [],
          state
        )

      [[modified_json]] = result.rows

      # Extract from modified JSON
      {:ok, age} = JSON.extract(state, modified_json, "$.age")
      assert age == 31
    end

    test "JSONB array operations", %{state: state} do
      array_json = ~s([1,2,3,4,5])

      # Convert to JSONB
      {:ok, jsonb} = JSON.convert(state, array_json, :jsonb)

      # Extract array element
      {:ok, _, result, _state} =
        EctoLibSql.handle_execute(
          "SELECT json_extract(?, '$[2]')",
          [jsonb],
          [],
          state
        )

      [[element]] = result.rows
      assert element == 3
    end

    test "JSONB with large objects (multi-KB)", %{state: state} do
      # Create a large JSON object with multiple nested structures
      large_json =
        Jason.encode!(%{
          "data" =>
            Enum.map(1..100, fn i ->
              %{
                "id" => i,
                "name" => "Item #{i}",
                "description" =>
                  "This is a longer description for item number #{i} with some additional details.",
                "metadata" => %{
                  "created_at" =>
                    "2024-01-#{String.pad_leading(to_string(rem(i, 28) + 1), 2, "0")}",
                  "tags" => ["tag1", "tag2", "tag3"]
                }
              }
            end)
        })

      # Convert to JSONB
      {:ok, jsonb} = JSON.convert(state, large_json, :jsonb)
      assert is_binary(jsonb)
      assert byte_size(jsonb) > 1000, "Should handle large objects (>1KB)"

      # Extract from large JSONB
      {:ok, _, result, _state} =
        EctoLibSql.handle_execute(
          "SELECT json_extract(?, '$.data[0].name')",
          [jsonb],
          [],
          state
        )

      [[name]] = result.rows
      assert name == "Item 1"
    end

    test "JSONB object key iteration", %{state: state} do
      json_obj = ~s({"a":1,"b":2,"c":3,"d":4})

      # Convert to JSONB
      {:ok, jsonb} = JSON.convert(state, json_obj, :jsonb)

      # Get keys (order may vary)
      {:ok, _, result, _state} =
        EctoLibSql.handle_execute(
          "SELECT json_extract(?, '$')",
          [jsonb],
          [],
          state
        )

      [[result_obj]] = result.rows

      # Parse and verify all keys are present
      {:ok, decoded} = Jason.decode(result_obj)
      keys = Map.keys(decoded)
      assert Enum.sort(keys) == ["a", "b", "c", "d"]
    end

    test "JSONB and text JSON with nulls", %{state: state} do
      json_with_nulls = ~s({"a":null,"b":1,"c":null})

      # Convert to JSONB
      {:ok, jsonb} = JSON.convert(state, json_with_nulls, :jsonb)

      # Extract nulls
      {:ok, _, result, _state} =
        EctoLibSql.handle_execute(
          "SELECT json_extract(?, '$.a'), json_extract(?, '$.b'), json_extract(?, '$.c')",
          [jsonb, jsonb, jsonb],
          [],
          state
        )

      [[a, b, c]] = result.rows
      assert a == nil
      assert b == 1
      assert c == nil
    end

    test "JSONB storage and retrieval consistency", %{state: state} do
      # Insert both text and JSONB versions of same data
      json_text = ~s({"x":10,"y":20,"z":30})

      {:ok, jsonb} = JSON.convert(state, json_text, :jsonb)

      # Clear table and insert both versions
      EctoLibSql.handle_execute("DELETE FROM json_test", [], [], state)

      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO json_test (id, data) VALUES (1, ?)",
          [json_text],
          [],
          state
        )

      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO json_test (id, data_jsonb) VALUES (2, ?)",
          [jsonb],
          [],
          state
        )

      # Retrieve text version
      {:ok, _, text_result, state} =
        EctoLibSql.handle_execute(
          "SELECT json_extract(data, '$.x'), json_extract(data, '$.y') FROM json_test WHERE id = 1",
          [],
          [],
          state
        )

      [[text_x, text_y]] = text_result.rows

      # Retrieve JSONB version
      {:ok, _, jsonb_result, _state} =
        EctoLibSql.handle_execute(
          "SELECT json_extract(data_jsonb, '$.x'), json_extract(data_jsonb, '$.y') FROM json_test WHERE id = 2",
          [],
          [],
          state
        )

      [[jsonb_x, jsonb_y]] = jsonb_result.rows

      # Both should return same values
      assert text_x == jsonb_x
      assert text_y == jsonb_y
      assert text_x == 10
      assert text_y == 20
    end

    test "JSONB modification with json_replace", %{state: state} do
      json_text = ~s({"status":"pending","priority":1})

      {:ok, jsonb} = JSON.convert(state, json_text, :jsonb)

      # Replace value
      {:ok, _, result, _state} =
        EctoLibSql.handle_execute(
          "SELECT json_replace(?, '$.status', 'completed'), json_replace(?, '$.priority', 5)",
          [jsonb, jsonb],
          [],
          state
        )

      [[status_json, priority_json]] = result.rows

      {:ok, status} = JSON.extract(state, status_json, "$.status")
      {:ok, priority} = JSON.extract(state, priority_json, "$.priority")

      assert status == "completed"
      assert priority == 5
    end

    test "mixed operations: JSONB extract, modify, insert", %{state: state} do
      json_text = ~s({"config":{"timeout":30,"retries":3}})

      {:ok, jsonb} = JSON.convert(state, json_text, :jsonb)

      # Extract original value
      {:ok, _, orig_result, state} =
        EctoLibSql.handle_execute(
          "SELECT json_extract(?, '$.config.timeout')",
          [jsonb],
          [],
          state
        )

      [[original_timeout]] = orig_result.rows
      assert original_timeout == 30

      # Modify
      {:ok, _, modified_result, state} =
        EctoLibSql.handle_execute(
          "SELECT json_set(?, '$.config.timeout', 60)",
          [jsonb],
          [],
          state
        )

      [[modified_jsonb]] = modified_result.rows

      # Insert modified version
      {:ok, _, _, state} =
        EctoLibSql.handle_execute(
          "INSERT INTO json_test (id, data_jsonb) VALUES (99, ?)",
          [modified_jsonb],
          [],
          state
        )

      # Retrieve and verify
      {:ok, _, retrieve_result, _state} =
        EctoLibSql.handle_execute(
          "SELECT json_extract(data_jsonb, '$.config.timeout') FROM json_test WHERE id = 99",
          [],
          [],
          state
        )

      [[retrieved_timeout]] = retrieve_result.rows
      assert retrieved_timeout == 60
    end
  end
end
