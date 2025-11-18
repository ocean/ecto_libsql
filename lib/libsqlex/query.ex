defmodule LibSqlEx.Query do
  defstruct [:statement, :name, :prepared, :param_types, type: :binary]

  defimpl DBConnection.Query do
    def parse(query, _opts), do: query

    def describe(query, _opts), do: query

    def encode(_query, params, _opts), do: params

    def decode(_query, result, _opts), do: result
  end

  defimpl String.Chars do
    def to_string(%LibSqlEx.Query{statement: statement}) do
      statement
    end
  end
end
