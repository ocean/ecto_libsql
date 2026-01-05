defmodule EctoLibSql.JSON do
  @moduledoc """
  Helper functions for working with JSON and JSONB data in SQLite.

  libSQL 3.45.1 has comprehensive JSON1 extension built into the core with support for:
  - JSON and JSONB (binary format) types
  - Full suite of JSON functions: json_extract, json_type, json_array, json_object, json_each, json_tree
  - MySQL/PostgreSQL compatible -> and ->> operators
  - JSONB binary format for 5-10% smaller storage and faster processing

  ## JSON Functions

  All JSON functions work with both text JSON and JSONB binary format. The functions
  accept either format and automatically convert as needed.

  ### Core Functions

  - `json_extract(json, path)` - Extract value at path
  - `json_type(json, path)` - Get type of value at path (null, true, false, integer, real, text, array, object)
  - `json_array(...args)` - Create JSON array from arguments
  - `json_object(...pairs)` - Create JSON object from key-value pairs
  - `json_each(json, path)` - Iterate over array/object members
  - `json_tree(json, path)` - Recursively iterate over all values
  - `json_valid(json)` - Check if JSON is valid
  - `json(json)` - Convert text to canonical JSON representation
  - `jsonb(json)` - Convert to binary JSONB format

  ### Operators

  - `json -> 'path'` - Extract as JSON (always returns JSON or NULL)
  - `json ->> 'path'` - Extract as text/SQL type (auto-converts)
  - `json -> 'key'` - PostgreSQL-style shorthand for object keys
  - `json -> 2` - PostgreSQL-style shorthand for array indices

  ## Usage with Ecto

  JSON functions work naturally in Ecto queries via fragments:

      from u in User,
        where: json_extract(u.settings, "$.theme") == "dark",
        select: {u.id, u.settings -> "theme"}

  Or use the helpers in this module:

      from u in User,
        where: fragment("json_extract(?, ?) = ?", u.settings, "$.theme", "dark"),
        select: {u.id, json_extract(u.settings, "$.theme")}

  ## JSONB Binary Format

  JSONB is an efficient binary encoding of JSON with these benefits:
  - 5-10% smaller file size than text JSON
  - Faster processing (less than half the CPU cycles)
  - Backwards compatible: all JSON functions accept both text and JSONB
  - Transparent format conversion

  Store as JSONB:
      {ok, _} = Repo.query("INSERT INTO users (data) VALUES (jsonb(?))", [json_string])

  Retrieve and auto-convert:
      {:ok, result} = Repo.query("SELECT json(data) FROM users")

  ## Examples

      # Extract nested value
      {:ok, theme} = EctoLibSql.JSON.extract(state, data, "$.user.preferences.theme")

      # Create JSON object
      {:ok, obj} = EctoLibSql.JSON.object(state, ["name", "Alice", "age", 30])

      # Validate JSON
      {:ok, valid?} = EctoLibSql.JSON.is_valid(state, json_string)

      # Iterate over array elements
      {:ok, items} = EctoLibSql.JSON.each(state, array_json)

  """

  alias EctoLibSql.{Native, State}

  @doc """
  Extract a value from JSON at the specified path.

  ## Parameters

    - state: Connection state
    - json: JSON text or JSONB binary data
    - path: JSON path expression (e.g., "$.key" or "$[0]" or "$.nested.path")

  ## Returns

    - `{:ok, value}` - Extracted value, or nil if path doesn't exist
    - `{:error, reason}` on failure

  ## Examples

      {:ok, theme} = EctoLibSql.JSON.extract(state, ~s({"theme":"dark"}), "$.theme")
      # Returns: {:ok, "dark"}

      {:ok, age} = EctoLibSql.JSON.extract(state, ~s({"user":{"age":30}}), "$.user.age")
      # Returns: {:ok, 30}

  ## Notes

  - Returns JSON types as-is (objects and arrays returned as JSON text)
  - Use json_extract to preserve JSON structure, or ->> operator to convert to SQL types
  - Works with both text JSON and JSONB binary format

  """
  @spec extract(State.t(), String.t() | binary, String.t()) :: {:ok, term()} | {:error, term()}
  def extract(%State{} = state, json, path) when is_binary(json) and is_binary(path) do
    # Execute: SELECT json_extract(?, ?)
    case Native.query_args(
      state.conn_id,
      state.mode,
      :disable_sync,
      "SELECT json_extract(?, ?)",
      [json, path]
    ) do
      %{"rows" => [[value]]} ->
        {:ok, value}

      %{"rows" => []} ->
        {:ok, nil}

      %{"error" => reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_response, other}}
    end
  end

  @doc """
  Get the type of a value in JSON at the specified path.

  ## Parameters

    - state: Connection state
    - json: JSON text or JSONB binary data
    - path: JSON path expression (optional, defaults to "$" for root)

  ## Returns

    - `{:ok, type}` - One of: null, true, false, integer, real, text, array, object
    - `{:error, reason}` on failure

  ## Examples

      {:ok, type} = EctoLibSql.JSON.type(state, ~s([1,2,3]), "$")
      # Returns: {:ok, "array"}

      {:ok, type} = EctoLibSql.JSON.type(state, ~s({"name":"Alice"}), "$.name")
      # Returns: {:ok, "text"}

  """
  @spec type(State.t(), String.t() | binary, String.t()) :: {:ok, String.t()} | {:error, term()}
  def type(%State{} = state, json, path \\ "$") when is_binary(json) and is_binary(path) do
    case Native.query_args(
      state.conn_id,
      state.mode,
      :disable_sync,
      "SELECT json_type(?, ?)",
      [json, path]
    ) do
      %{"rows" => [[type_val]]} ->
        {:ok, type_val}

      %{"rows" => []} ->
        {:ok, nil}

      %{"error" => reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_response, other}}
    end
  end

  @doc """
  Check if a string is valid JSON.

  ## Parameters

    - state: Connection state
    - json: String to validate as JSON

  ## Returns

    - `{:ok, true}` if valid JSON
    - `{:ok, false}` if not valid JSON
    - `{:error, reason}` on failure

  ## Examples

      {:ok, true} = EctoLibSql.JSON.is_valid(state, ~s({"valid":true}))
      {:ok, false} = EctoLibSql.JSON.is_valid(state, "not json")

  """
  @spec is_valid(State.t(), String.t()) :: {:ok, boolean()} | {:error, term()}
  def is_valid(%State{} = state, json) when is_binary(json) do
    case Native.query_args(
      state.conn_id,
      state.mode,
      :disable_sync,
      "SELECT json_valid(?)",
      [json]
    ) do
      %{"rows" => [[1]]} ->
        {:ok, true}

      %{"rows" => [[0]]} ->
        {:ok, false}

      %{"error" => reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_response, other}}
    end
  end

  @doc """
  Create a JSON array from a list of values.

  Each value will be inserted as-is, with strings becoming JSON text,
  numbers becoming JSON numbers, nil becoming null, etc.

  ## Parameters

    - state: Connection state
    - values: List of values to include in the array

  ## Returns

    - `{:ok, json_array}` - JSON text representation of the array
    - `{:error, reason}` on failure

  ## Examples

      {:ok, array} = EctoLibSql.JSON.array(state, [1, 2.5, "hello", nil])
      # Returns: {:ok, "[1,2.5,\"hello\",null]"}

      # To nest JSON objects, pass them as json_object results
      {:ok, obj} = EctoLibSql.JSON.object(state, ["name", "Alice"])
      {:ok, array} = EctoLibSql.JSON.array(state, [obj, 42])

  """
  @spec array(State.t(), list()) :: {:ok, String.t()} | {:error, term()}
  def array(%State{} = state, values) when is_list(values) do
    placeholders = Enum.map(values, fn _ -> "?" end) |> Enum.join(",")
    sql = "SELECT json_array(#{placeholders})"

    case Native.query_args(
      state.conn_id,
      state.mode,
      :disable_sync,
      sql,
      values
    ) do
      %{"rows" => [[json_array]]} ->
        {:ok, json_array}

      %{"error" => reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_response, other}}
    end
  end

  @doc """
  Create a JSON object from a list of key-value pairs.

  Arguments must alternate between string keys and values. Values can be
  of any type (strings, numbers, nil/null, nested objects/arrays, etc.).

  ## Parameters

    - state: Connection state
    - pairs: List of alternating [key1, value1, key2, value2, ...]

  ## Returns

    - `{:ok, json_object}` - JSON text representation of the object
    - `{:error, reason}` on failure

  ## Examples

      {:ok, obj} = EctoLibSql.JSON.object(state, ["name", "Alice", "age", 30])
      # Returns: {:ok, "{\"name\":\"Alice\",\"age\":30}"}

      # Keys must be strings, values can be any type
      {:ok, obj} = EctoLibSql.JSON.object(state, [
        "id", 1,
        "active", true,
        "balance", 99.99,
        "tags", nil
      ])

  ## Errors

  Returns `{:error, reason}` if:
  - Number of arguments is not even
  - Any key is not a string

  """
  @spec object(State.t(), list()) :: {:ok, String.t()} | {:error, term()}
  def object(%State{} = state, pairs) when is_list(pairs) do
    if rem(length(pairs), 2) != 0 do
      {:error, {:invalid_arguments, "json_object requires even number of arguments"}}
    else
      placeholders = Enum.map(pairs, fn _ -> "?" end) |> Enum.join(",")
      sql = "SELECT json_object(#{placeholders})"

      case Native.query_args(
        state.conn_id,
        state.mode,
        :disable_sync,
        sql,
        pairs
      ) do
        %{"rows" => [[json_object]]} ->
          {:ok, json_object}

        %{"error" => reason} ->
          {:error, reason}

        {:error, reason} ->
          {:error, reason}

        other ->
          {:error, {:unexpected_response, other}}
      end
    end
  end

  @doc """
  Iterate over elements of a JSON array or object members.

  For arrays: Returns one row per array element with keys, values, and types.
  For objects: Returns one row per key-value pair.

  ## Parameters

    - state: Connection state
    - json: JSON text or JSONB binary data
    - path: JSON path expression (optional, defaults to "$")

  ## Returns

    - `{:ok, [{key, value, type}]}` - List of members with metadata
    - `{:error, reason}` on failure

  ## Examples

      {:ok, items} = EctoLibSql.JSON.each(state, ~s([1,2,3]), "$")
      # Returns: {:ok, [{0, 1, "integer"}, {1, 2, "integer"}, {2, 3, "integer"}]}

      {:ok, items} = EctoLibSql.JSON.each(state, ~s({"a":1,"b":2}), "$")
      # Returns: {:ok, [{"a", 1, "integer"}, {"b", 2, "integer"}]}

  ## Notes

  This function requires the virtual table extension (json_each).
  Use in Ecto queries via fragments if the adapter doesn't support virtual tables.

  """
  @spec each(State.t(), String.t() | binary, String.t()) ::
          {:ok, [{String.t() | non_neg_integer(), term(), String.t()}]} | {:error, term()}
  def each(%State{} = state, json, path \\ "$") when is_binary(json) and is_binary(path) do
    sql = "SELECT key, value, type FROM json_each(?, ?)"

    case Native.query_args(
      state.conn_id,
      state.mode,
      :disable_sync,
      sql,
      [json, path]
    ) do
      %{"rows" => rows} ->
        items = Enum.map(rows, fn [key, value, type] ->
          {key, value, type}
        end)
        {:ok, items}

      %{"error" => reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_response, other}}
    end
  end

  @doc """
  Recursively iterate over all values in a JSON structure.

  Returns all values at all levels of nesting with their paths and types.
  Useful for flattening JSON or finding all values matching criteria.

  ## Parameters

    - state: Connection state
    - json: JSON text or JSONB binary data
    - path: JSON path expression (optional, defaults to "$")

  ## Returns

    - `{:ok, [{full_key, atom, type}]}` - List of all values with paths
    - `{:error, reason}` on failure

  ## Examples

      {:ok, tree} = EctoLibSql.JSON.tree(state, ~s({"a":{"b":1},"c":[2,3]}), "$")
      # Returns complete tree of all values with their full paths

  ## Notes

  This function requires the virtual table extension (json_tree).
  Returns more detailed information than json_each (includes all nested values).

  """
  @spec tree(State.t(), String.t() | binary, String.t()) ::
          {:ok, [{String.t(), term(), String.t()}]} | {:error, term()}
  def tree(%State{} = state, json, path \\ "$") when is_binary(json) and is_binary(path) do
    sql = "SELECT fullkey, atom, type FROM json_tree(?, ?)"

    case Native.query_args(
      state.conn_id,
      state.mode,
      :disable_sync,
      sql,
      [json, path]
    ) do
      %{"rows" => rows} ->
        items = Enum.map(rows, fn [fullkey, atom, type] ->
          {fullkey, atom, type}
        end)
        {:ok, items}

      %{"error" => reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_response, other}}
    end
  end

  @doc """
  Convert text JSON to canonical form, optionally returning JSONB binary format.

  Use `json()` to normalize and validate JSON text.
  Use `jsonb()` to convert to binary format for more efficient storage/processing.

  ## Parameters

    - state: Connection state
    - json: JSON text string
    - format: `:json` for text format (default) or `:jsonb` for binary format

  ## Returns

    - `{:ok, json}` - Canonical JSON text (if format: :json)
    - `{:ok, jsonb}` - Binary JSONB blob (if format: :jsonb)
    - `{:error, reason}` on failure

  ## Examples

      # Normalize JSON text
      {:ok, canonical} = EctoLibSql.JSON.convert(state, ~s(  {"a":1}  ), :json)
      # Returns: {:ok, "{\"a\":1}"}

      # Convert to binary format
      {:ok, binary} = EctoLibSql.JSON.convert(state, ~s({"a":1}), :jsonb)
      # Returns: {:ok, <<binary_data>>}

  ## Benefits of JSONB

  - 5-10% smaller file size
  - Less than half the processing time
  - Backwards compatible: all JSON functions accept JSONB
  - Automatic format conversion between text and binary

  """
  @spec convert(State.t(), String.t(), :json | :jsonb) :: {:ok, String.t() | binary()} | {:error, term()}
  def convert(%State{} = state, json, format \\ :json) when is_binary(json) do
    sql = case format do
      :json -> "SELECT json(?)"
      :jsonb -> "SELECT jsonb(?)"
      _ -> raise ArgumentError, "format must be :json or :jsonb"
    end

    case Native.query_args(
      state.conn_id,
      state.mode,
      :disable_sync,
      sql,
      [json]
    ) do
      %{"rows" => [[converted]]} ->
        {:ok, converted}

      %{"error" => reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_response, other}}
    end
  end

  @doc """
  Helper to create SQL fragments for Ecto queries using JSON operators.

  The -> and ->> operators are more concise in SQL than json_extract() calls.

  ## Parameters

    - json_column: Column name or fragment
    - path: JSON path (string or integer)
    - operator: `:arrow` for "->" (returns JSON) or `:double_arrow` for "->>" (returns SQL type)

  ## Returns

    - String for use in Ecto.Query.fragment/1

  ## Examples

      import Ecto.Query

      # Using arrow operator (returns JSON)
      from u in User,
        where: fragment(EctoLibSql.JSON.arrow_fragment("settings", "theme"), "!=", "null"),
        select: u

      # Using double-arrow operator (returns text/SQL type)
      from u in User,
        where: fragment(EctoLibSql.JSON.arrow_fragment("settings", "theme", :double_arrow), "=", "dark")

  ## Operators

  - `->`  - Returns JSON value or NULL
  - `->>` - Converts to SQL type (text, integer, real, or NULL)

  Both operators support abbreviated syntax for object keys and array indices:
  - `json -> 'key'` equivalent to `json_extract(json, '$.key')`
  - `json -> 0` equivalent to `json_extract(json, '$[0]')`

  """
  @spec arrow_fragment(String.t(), String.t() | integer, :arrow | :double_arrow) :: String.t()
  def arrow_fragment(json_column, path, operator \\ :arrow)

  def arrow_fragment(json_column, path, :arrow) when is_binary(json_column) and is_binary(path) do
    "#{json_column} -> '#{path}'"
  end

  def arrow_fragment(json_column, index, :arrow) when is_binary(json_column) and is_integer(index) do
    "#{json_column} -> #{index}"
  end

  def arrow_fragment(json_column, path, :double_arrow) when is_binary(json_column) and is_binary(path) do
    "#{json_column} ->> '#{path}'"
  end

  def arrow_fragment(json_column, index, :double_arrow) when is_binary(json_column) and is_integer(index) do
    "#{json_column} ->> #{index}"
  end
end
