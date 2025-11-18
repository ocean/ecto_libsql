defmodule EctoLibSql.Query do
  @moduledoc """
  Query structure and DBConnection.Query protocol implementation for EctoLibSql.

  This module defines the query structure used throughout the adapter and implements
  the `DBConnection.Query` protocol, which handles query parsing, encoding, and decoding.

  ## Fields

    * `:statement` - The SQL statement string to execute
    * `:name` - Optional name for the query
    * `:prepared` - Whether the query has been prepared
    * `:param_types` - Parameter type information for the query
    * `:type` - Query type (defaults to `:binary`)

  ## Protocol Implementation

  The `DBConnection.Query` protocol is implemented as a pass-through, delegating
  most operations to the native layer:

    * `parse/2` - Returns the query unchanged
    * `describe/2` - Returns the query unchanged
    * `encode/3` - Returns parameters unchanged
    * `decode/3` - Returns the result unchanged

  """

  @type t :: %__MODULE__{
          statement: String.t() | nil,
          name: String.t() | nil,
          prepared: boolean() | nil,
          param_types: list() | nil,
          type: :binary
        }

  defstruct [:statement, :name, :prepared, :param_types, type: :binary]

  defimpl DBConnection.Query do
    @moduledoc """
    DBConnection.Query protocol implementation for EctoLibSql queries.

    This implementation provides a minimal pass-through approach, as most
    query processing is handled by the underlying Rust NIF layer.
    """

    @doc """
    Parses a query. Returns the query unchanged as parsing is handled by the native layer.
    """
    def parse(query, _opts), do: query

    @doc """
    Describes a query. Returns the query unchanged as description is handled by the native layer.
    """
    def describe(query, _opts), do: query

    @doc """
    Encodes query parameters. Returns parameters unchanged as encoding is handled by the native layer.
    """
    def encode(_query, params, _opts), do: params

    @doc """
    Decodes query results. Returns the result unchanged as decoding is handled by the native layer.
    """
    def decode(_query, result, _opts), do: result
  end
end
