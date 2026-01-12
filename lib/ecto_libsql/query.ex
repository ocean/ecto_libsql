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

    # Convert Elixir types to SQLite-compatible values before sending to NIF.
    # Rustler cannot automatically serialise complex Elixir structs like DateTime,
    # so we convert them to ISO8601 strings that SQLite can handle.
    def encode(_query, params, _opts) when is_list(params) do
      Enum.map(params, &encode_param/1)
    end

    def encode(_query, params, _opts), do: params

    defp encode_param(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
    defp encode_param(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
    defp encode_param(%Date{} = d), do: Date.to_iso8601(d)
    defp encode_param(%Time{} = t), do: Time.to_iso8601(t)
    defp encode_param(%Decimal{} = d), do: Decimal.to_string(d)
    defp encode_param(value), do: value

    # Pass through results from Native.ex unchanged.
    # Native.ex already handles proper normalisation of columns and rows.
    def decode(_query, result, _opts), do: result
  end

  defimpl String.Chars do
    @moduledoc false

    def to_string(%EctoLibSql.Query{statement: statement}) do
      statement
    end
  end
end
