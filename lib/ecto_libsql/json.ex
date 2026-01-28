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

  The return type depends on the extracted JSON value:
    - `{:ok, string}` - For JSON text values (e.g., "dark")
    - `{:ok, integer}` - For JSON integer values (e.g., 30)
    - `{:ok, float}` - For JSON real/float values (e.g., 99.99)
    - `{:ok, nil}` - For JSON null values or non-existent paths
    - `{:ok, json_text}` - For JSON objects/arrays, returned as JSON text string
    - `{:error, reason}` - On query failure

  ## Examples

      {:ok, theme} = EctoLibSql.JSON.extract(state, ~s({"theme":"dark"}), "$.theme")
      # Returns: {:ok, "dark"}

      {:ok, age} = EctoLibSql.JSON.extract(state, ~s({"user":{"age":30}}), "$.user.age")
      # Returns: {:ok, 30}

      {:ok, items} = EctoLibSql.JSON.extract(state, ~s({"items":[1,2,3]}), "$.items")
      # Returns: {:ok, "[1,2,3]"}  (JSON array as text)

      {:ok, nil} = EctoLibSql.JSON.extract(state, ~s({"a":1}), "$.missing")
      # Returns: {:ok, nil}  (path doesn't exist)

  ## Notes

  - JSON objects and arrays are returned as JSON text strings
  - Use `-> operator in SQL queries to preserve JSON structure, or `->> operator to convert to SQL types
  - Works with both text JSON and JSONB binary format (format conversion is automatic)
  - For nested JSON structures, you can chain extractions or use JSON paths like "$.user.address.city"

  """
  @spec extract(State.t(), String.t() | binary, String.t()) ::
          {:ok, String.t() | integer() | float() | nil} | {:error, term()}
  def extract(%State{} = state, json, path) when is_binary(json) and is_binary(path) do
    Native.query_args(
      state.conn_id,
      state.mode,
      :disable_sync,
      "SELECT json_extract(?, ?)",
      [json, path]
    )
    |> handle_single_result()
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
    Native.query_args(
      state.conn_id,
      state.mode,
      :disable_sync,
      "SELECT json_type(?, ?)",
      [json, path]
    )
    |> handle_single_result()
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
    Native.query_args(
      state.conn_id,
      state.mode,
      :disable_sync,
      "SELECT json_valid(?)",
      [json]
    )
    |> handle_boolean_result()
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

    Native.query_args(
      state.conn_id,
      state.mode,
      :disable_sync,
      sql,
      values
    )
    |> handle_single_result()
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

      Native.query_args(
        state.conn_id,
        state.mode,
        :disable_sync,
        sql,
        pairs
      )
      |> handle_single_result()
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

    Native.query_args(
      state.conn_id,
      state.mode,
      :disable_sync,
      sql,
      [json, path]
    )
    |> handle_multiple_rows(fn [key, value, type] -> {key, value, type} end)
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

    Native.query_args(
      state.conn_id,
      state.mode,
      :disable_sync,
      sql,
      [json, path]
    )
    |> handle_multiple_rows(fn [fullkey, atom, type] -> {fullkey, atom, type} end)
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
  @spec convert(State.t(), String.t(), :json | :jsonb) ::
          {:ok, String.t() | binary()} | {:error, term()}
  def convert(%State{} = state, json, format \\ :json) when is_binary(json) do
    sql =
      case format do
        :json -> "SELECT json(?)"
        :jsonb -> "SELECT jsonb(?)"
        _ -> raise ArgumentError, "format must be :json or :jsonb"
      end

    Native.query_args(
      state.conn_id,
      state.mode,
      :disable_sync,
      sql,
      [json]
    )
    |> handle_single_result()
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
    validate_identifier!(json_column)
    escaped_path = escape_sql_string(path)
    "#{json_column} -> '#{escaped_path}'"
  end

  def arrow_fragment(json_column, index, :arrow)
      when is_binary(json_column) and is_integer(index) do
    validate_identifier!(json_column)
    "#{json_column} -> #{index}"
  end

  def arrow_fragment(json_column, path, :double_arrow)
      when is_binary(json_column) and is_binary(path) do
    validate_identifier!(json_column)
    escaped_path = escape_sql_string(path)
    "#{json_column} ->> '#{escaped_path}'"
  end

  def arrow_fragment(json_column, index, :double_arrow)
      when is_binary(json_column) and is_integer(index) do
    validate_identifier!(json_column)
    "#{json_column} ->> #{index}"
  end

  # Private helper: Validate json_column is a safe identifier
  defp validate_identifier!(identifier) do
    safe_identifier_pattern = ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/

    unless String.match?(identifier, safe_identifier_pattern) do
      raise ArgumentError,
            "json_column must be a valid SQL identifier (alphanumeric, underscore, starting with letter or underscore), got: #{inspect(identifier)}"
    end
  end

  # Private helper: Escape single quotes in SQL strings by doubling them
  defp escape_sql_string(str) do
    String.replace(str, "'", "''")
  end

  # Private helpers: Result handling patterns
  # All Native.query_args/5 calls return a response map from Rust that needs handling.
  # These helpers reduce duplication and provide consistent error handling.
  #
  # Expected response shape from Native.query_args/5:
  #   %{
  #     "columns" => [list of column names],
  #     "rows" => [list of result rows, where each row is a list of values],
  #     "num_rows" => total number of rows
  #   }
  #
  # Error responses are:
  #   %{"error" => reason_string}  (from Rust)
  #   {:error, reason}             (from Elixir error handling)

  @doc false
  defp handle_single_result(response) do
    case response do
      %{"rows" => [[value]]} -> {:ok, value}
      %{"rows" => []} -> {:ok, nil}
      %{"error" => reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_response, other}}
    end
  end

  @doc false
  defp handle_boolean_result(response) do
    case response do
      %{"rows" => [[1]]} -> {:ok, true}
      %{"rows" => [[0]]} -> {:ok, false}
      %{"error" => reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_response, other}}
    end
  end

  @doc false
  defp handle_nullable_result(response) do
    case response do
      %{"rows" => [[value]]} -> {:ok, value}
      %{"rows" => [[]]} -> {:ok, nil}
      %{"rows" => []} -> {:ok, nil}
      %{"error" => reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_response, other}}
    end
  end

  @doc false
  defp handle_multiple_rows(response, transform_fn) do
    case response do
      %{"rows" => rows} ->
        items = Enum.map(rows, transform_fn)
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
  Quote a value for use in JSON.

  Converts SQL values to properly escaped JSON string representation.
  Useful for building JSON values dynamically.

  Named `json_quote/2` to avoid shadowing Elixir's Kernel.quote/2 macro.

  ## Parameters

    - state: Connection state
    - value: Value to quote (string, number, nil, etc.)

  ## Returns

    - `{:ok, json_string}` - Properly quoted JSON string
    - `{:error, reason}` on failure

  ## Examples

      {:ok, quoted} = EctoLibSql.JSON.json_quote(state, "hello \"world\"")
      # Returns: {:ok, "\"hello \\\"world\\\"\""}

      {:ok, quoted} = EctoLibSql.JSON.json_quote(state, "test")
      # Returns: {:ok, "\"test\""}

  """
  @spec json_quote(State.t(), term()) :: {:ok, String.t()} | {:error, term()}
  def json_quote(%State{} = state, value) do
    Native.query_args(
      state.conn_id,
      state.mode,
      :disable_sync,
      "SELECT json_quote(?)",
      [value]
    )
    |> handle_single_result()
  end

  @doc """
  Get the length of a JSON array or number of keys in JSON object.

  Named `json_length/2,3` to avoid shadowing Elixir's `Kernel.length/1`.

  ## Parameters

    - state: Connection state
    - json: JSON text or JSONB binary data
    - path: JSON path expression (optional, defaults to "$")

  ## Returns

    - `{:ok, length}` - Number of elements/keys
    - `{:ok, nil}` - For non-array/object values
    - `{:error, reason}` on failure

  ## Examples

      {:ok, len} = EctoLibSql.JSON.json_length(state, ~s([1,2,3]))
      # Returns: {:ok, 3}

      {:ok, len} = EctoLibSql.JSON.json_length(state, ~s({"a":1,"b":2}))
      # Returns: {:ok, 2}

  """
  @spec json_length(State.t(), String.t() | binary, String.t()) ::
          {:ok, non_neg_integer() | nil} | {:error, term()}
  def json_length(%State{} = state, json, path \\ "$") when is_binary(json) and is_binary(path) do
    Native.query_args(
      state.conn_id,
      state.mode,
      :disable_sync,
      "SELECT json_length(?, ?)",
      [json, path]
    )
    |> handle_single_result()
  end

  @doc """
  Get the depth of a JSON structure.

  Returns the maximum depth of nesting. Scalars have depth 1, empty arrays/objects have depth 1,
  nested structures return greater depths.

  ## Parameters

    - state: Connection state
    - json: JSON text or JSONB binary data

  ## Returns

    - `{:ok, depth}` - Maximum nesting depth
    - `{:error, reason}` on failure

  ## Examples

      {:ok, depth} = EctoLibSql.JSON.depth(state, ~s(1))
      # Returns: {:ok, 1}

      {:ok, depth} = EctoLibSql.JSON.depth(state, ~s([1,2,3]))
      # Returns: {:ok, 2}

      {:ok, depth} = EctoLibSql.JSON.depth(state, ~s({"a":{"b":1}}))
      # Returns: {:ok, 3}

  """
  @spec depth(State.t(), String.t() | binary) :: {:ok, pos_integer()} | {:error, term()}
  def depth(%State{} = state, json) when is_binary(json) do
    Native.query_args(
      state.conn_id,
      state.mode,
      :disable_sync,
      "SELECT json_depth(?)",
      [json]
    )
    |> handle_single_result()
  end

  @doc """
  Remove one or more elements from JSON.

  ## Parameters

    - state: Connection state
    - json: JSON text or JSONB binary data
    - paths: Single path string or list of path strings to remove

  ## Returns

    - `{:ok, modified_json}` - JSON with specified paths removed
    - `{:error, reason}` on failure

  ## Examples

      {:ok, json} = EctoLibSql.JSON.remove(state, ~s({"a":1,"b":2,"c":3}), "$.b")
      # Returns: {:ok, "{\"a\":1,\"c\":3}"}

      {:ok, json} = EctoLibSql.JSON.remove(state, ~s([1,2,3,4,5]), ["$[0]", "$[2]"])
      # Returns: {:ok, "[2,3,5]"}
      # Note: Paths are removed in order; after removing $[0], the original $[2] is now at $[1]

  """
  @spec remove(State.t(), String.t() | binary, String.t() | [String.t()]) ::
          {:ok, String.t()} | {:error, term()}
  def remove(%State{} = state, json, paths) when is_binary(json) do
    paths_list = if is_list(paths), do: paths, else: [paths]

    # Build SQL with json_remove: SELECT json_remove(json, path1, path2, ...)
    placeholders = ["?"] ++ List.duplicate("?", length(paths_list))
    sql = "SELECT json_remove(" <> Enum.join(placeholders, ", ") <> ")"

    args = [json] ++ paths_list

    Native.query_args(
      state.conn_id,
      state.mode,
      :disable_sync,
      sql,
      args
    )
    |> handle_single_result()
  end

  @doc """
  Set a value in JSON at a specific path.

  If the path does not exist, it is created. If the path exists, it is replaced.

  ## Parameters

    - state: Connection state
    - json: JSON text or JSONB binary data
    - path: JSON path where to set the value
    - value: Value to set at the path

  ## Returns

    - `{:ok, modified_json}` - JSON with updated value
    - `{:error, reason}` on failure

  ## Examples

      {:ok, json} = EctoLibSql.JSON.set(state, ~s({"a":1}), "$.b", 2)
      # Returns: {:ok, "{\"a\":1,\"b\":2}"}

      {:ok, json} = EctoLibSql.JSON.set(state, ~s({"user":"Alice"}), "$.active", true)
      # Returns: {:ok, "{\"user\":\"Alice\",\"active\":true}"}

  """
  @spec set(State.t(), String.t() | binary, String.t(), term()) ::
          {:ok, String.t()} | {:error, term()}
  def set(%State{} = state, json, path, value) when is_binary(json) and is_binary(path) do
    Native.query_args(
      state.conn_id,
      state.mode,
      :disable_sync,
      "SELECT json_set(?, ?, ?)",
      [json, path, value]
    )
    |> handle_single_result()
  end

  @doc """
  Replace a value in JSON at a specific path (if it exists).

  Unlike `set/4`, replace only modifies existing paths. Non-existent paths are ignored.

  ## Parameters

    - state: Connection state
    - json: JSON text or JSONB binary data
    - path: JSON path to replace
    - value: New value

  ## Returns

    - `{:ok, modified_json}` - JSON with replaced value
    - `{:error, reason}` on failure

  ## Examples

      {:ok, json} = EctoLibSql.JSON.replace(state, ~s({"a":1,"b":2}), "$.a", 10)
      # Returns: {:ok, "{\"a\":10,\"b\":2}"}

      # Non-existent path is ignored
      {:ok, json} = EctoLibSql.JSON.replace(state, ~s({"a":1}), "$.z", 99)
      # Returns: {:ok, "{\"a\":1}"}

  """
  @spec replace(State.t(), String.t() | binary, String.t(), term()) ::
          {:ok, String.t()} | {:error, term()}
  def replace(%State{} = state, json, path, value) when is_binary(json) and is_binary(path) do
    Native.query_args(
      state.conn_id,
      state.mode,
      :disable_sync,
      "SELECT json_replace(?, ?, ?)",
      [json, path, value]
    )
    |> handle_single_result()
  end

  @doc """
  Insert a value into JSON at a specific path.

  Adds a value without replacing existing content. For arrays, inserts before the specified index.

  ## Parameters

    - state: Connection state
    - json: JSON text or JSONB binary data
    - path: JSON path where to insert
    - value: Value to insert

  ## Returns

    - `{:ok, modified_json}` - JSON with inserted value
    - `{:error, reason}` on failure

  ## Examples

      {:ok, json} = EctoLibSql.JSON.insert(state, ~s([1,3,4]), "$[1]", 2)
      # Returns: {:ok, "[1,2,3,4]"}

      {:ok, json} = EctoLibSql.JSON.insert(state, ~s({"a":1}), "$.b", 2)
      # Returns: {:ok, "{\"a\":1,\"b\":2}"}

  """
  @spec insert(State.t(), String.t() | binary, String.t(), term()) ::
          {:ok, String.t()} | {:error, term()}
  def insert(%State{} = state, json, path, value) when is_binary(json) and is_binary(path) do
    Native.query_args(
      state.conn_id,
      state.mode,
      :disable_sync,
      "SELECT json_insert(?, ?, ?)",
      [json, path, value]
    )
    |> handle_single_result()
  end

  @doc """
  Apply a JSON Merge Patch to modify JSON (RFC 7396).

  Implements RFC 7396 JSON Merge Patch semantics. The patch is a JSON object where:
  - **Top-level keys** are object keys in the target, not JSON paths
  - **Values** replace the corresponding object values in the target
  - **Nested objects** are merged recursively
  - **null values** remove the key from the target object

  To update nested structures, the patch object must reflect the nesting level.

  ## Parameters

    - state: Connection state
    - json: JSON text or JSONB binary data (must be an object)
    - patch: JSON object with merge patch semantics (keys are object keys, not paths)

  ## Returns

    - `{:ok, modified_json}` - JSON after applying merge patch
    - `{:error, reason}` on failure

  ## Examples

      # Top-level key replacement
      {:ok, json} = EctoLibSql.JSON.patch(state, ~s({"a":1,"b":2}), ~s({"a":10}))
      # Returns: {:ok, "{\"a\":10,\"b\":2}"}

      # Add new top-level key
      {:ok, json} = EctoLibSql.JSON.patch(state, ~s({"a":1,"b":2}), ~s({"c":3}))
      # Returns: {:ok, "{\"a\":1,\"b\":2,\"c\":3}"}

      # Remove key with null
      {:ok, json} = EctoLibSql.JSON.patch(state, ~s({"a":1,"b":2,"c":3}), ~s({"b":null}))
      # Returns: {:ok, "{\"a\":1,\"c\":3}"}

      # Nested object merge (replaces entire nested object)
      {:ok, json} = EctoLibSql.JSON.patch(state, ~s({"user":{"name":"Alice","age":30}}), ~s({"user":{"age":31}}))
      # Returns: {:ok, "{\"user\":{\"age\":31}}"}  (replaces entire user object, not a deep merge)

  ## Notes

  - This implements RFC 7396 JSON Merge Patch, NOT RFC 6902 JSON Patch
  - Object keys in the patch are literal keys, not JSON paths (use "a" not "$.a")
  - For nested structures, the patch replaces the entire value at that key (not a deep recursive merge)
  - To perform deep merges or path-based updates, use `json_set/4` or `json_replace/4` instead
  - Works with both text JSON and JSONB binary format

  """
  @spec patch(State.t(), String.t() | binary, String.t() | binary) ::
          {:ok, String.t()} | {:error, term()}
  def patch(%State{} = state, json, patch_json) when is_binary(json) and is_binary(patch_json) do
    Native.query_args(
      state.conn_id,
      state.mode,
      :disable_sync,
      "SELECT json_patch(?, ?)",
      [json, patch_json]
    )
    |> handle_single_result()
  end

  @doc """
  Get all keys from a JSON object.

  Returns NULL if the JSON is not an object.

  ## Parameters

    - state: Connection state
    - json: JSON text or JSONB binary data
    - path: JSON path expression (optional, defaults to "$")

  ## Returns

    - `{:ok, keys}` - JSON array of keys
    - `{:ok, nil}` - If not an object
    - `{:error, reason}` on failure

  ## Examples

      {:ok, keys} = EctoLibSql.JSON.keys(state, ~s({"name":"Alice","age":30}))
      # Returns: {:ok, "[\"age\",\"name\"]"}  (sorted)

  """
  @spec keys(State.t(), String.t() | binary, String.t()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def keys(%State{} = state, json, path \\ "$") when is_binary(json) and is_binary(path) do
    Native.query_args(
      state.conn_id,
      state.mode,
      :disable_sync,
      "SELECT json_keys(?, ?)",
      [json, path]
    )
    |> handle_nullable_result()
  end
end
