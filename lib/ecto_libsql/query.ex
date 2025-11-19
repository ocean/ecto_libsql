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

  defstruct [:statement, :name, :prepared, :param_types, type: :binary]

  defimpl DBConnection.Query do
    @moduledoc false

    def parse(query, _opts), do: query

    def describe(query, _opts), do: query

    def encode(_query, params, _opts), do: params

    def decode(_query, result, _opts), do: result
  end

  defimpl String.Chars do
    @moduledoc false

    def to_string(%EctoLibSql.Query{statement: statement}) do
      statement
    end
  end
end
