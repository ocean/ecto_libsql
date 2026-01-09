defmodule EctoLibSql.Query do
  @moduledoc """
  Represents a database query in the EctoLibSql adapter.

  This struct holds the SQL statement and metadata about the query,
  implementing the `DBConnection.Query` protocol for compatibility
  with the DBConnection framework.

  ## Fields

  - `:statement` - The SQL query string
  - `:name` - Optional name for the query
  - `:prepared` - Whether the query is prepared
  - `:param_types` - Expected parameter types
  - `:type` - Query type (default: `:binary`)

  ## Examples

      %EctoLibSql.Query{statement: "SELECT * FROM users WHERE id = ?"}

  """

  @typedoc "Query struct for EctoLibSql."
  @type t :: %__MODULE__{
          statement: String.t() | nil,
          name: String.t() | nil,
          prepared: boolean() | nil,
          param_types: [atom()] | nil,
          type: :binary | :text
        }

  defstruct [:statement, :name, :prepared, :param_types, type: :binary]

  defimpl DBConnection.Query do
    @moduledoc false

    def parse(query, _opts), do: query

    def describe(query, _opts), do: query

    # Convert Elixir types to SQLite-compatible values before sending to NIF
    def encode(_query, params, _opts) do
      Enum.map(params, &encode_param/1)
    end

    defp encode_param(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
    defp encode_param(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
    defp encode_param(%Date{} = d), do: Date.to_iso8601(d)
    defp encode_param(%Time{} = t), do: Time.to_iso8601(t)
    defp encode_param(%Decimal{} = d), do: Decimal.to_string(d)
    defp encode_param(value), do: value

    # Normalize results for ecto_sql compatibility.
    # Rules:
    # 1. columns MUST ALWAYS be a list (even empty []), NEVER nil
    # 2. rows should be nil only for write commands without RETURNING that affected rows
    # 3. For all other cases (SELECT, RETURNING queries), rows must be a list
    def decode(_query, result, _opts) when is_map(result) do
      columns = case Map.get(result, :columns) do
        nil -> []
        cols when is_list(cols) -> cols
        _ -> []
      end

      cmd = Map.get(result, :command)
      rows = Map.get(result, :rows)
      num_rows = Map.get(result, :num_rows, 0)

      rows = cond do
        # Write commands that affected rows but have no RETURNING -> rows should be nil
        cmd in [:insert, :update, :delete] and rows == [] and num_rows > 0 and columns == [] ->
          nil
        # All other cases: rows must be a list
        rows == nil ->
          []
        true ->
          rows
      end

      result
      |> Map.put(:columns, columns)
      |> Map.put(:rows, rows)
    end

    def decode(_query, result, _opts), do: result
  end

  defimpl String.Chars do
    @moduledoc false

    def to_string(%EctoLibSql.Query{statement: statement}) do
      statement
    end
  end
end
