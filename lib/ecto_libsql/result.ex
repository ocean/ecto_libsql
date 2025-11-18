defmodule EctoLibSql.Result do
  @moduledoc """
  Result structure for query responses in EctoLibSql.

  This module defines the structure used to return query results from the database,
  including metadata about the command executed and the returned data.

  ## Fields

    * `:command` - The type of SQL command executed (`:select`, `:insert`, `:update`, `:delete`, or `:other`)
    * `:columns` - List of column names for SELECT queries (nil for non-SELECT queries)
    * `:rows` - List of rows, where each row is a list of values (nil for non-SELECT queries)
    * `:num_rows` - Number of rows affected or returned by the query

  ## Usage

  Results are typically created by the native layer and returned through the
  DBConnection callbacks. You can also create results manually using the `new/1` function:

      iex> EctoLibSql.Result.new(command: :select, columns: ["id", "name"], rows: [[1, "Alice"]], num_rows: 1)
      %EctoLibSql.Result{command: :select, columns: ["id", "name"], rows: [[1, "Alice"]], num_rows: 1}

  """

  defstruct command: nil,
            columns: nil,
            rows: nil,
            num_rows: 0

  @typedoc """
  The type of SQL command that was executed.

  Possible values:
    * `:select` - SELECT query
    * `:insert` - INSERT statement
    * `:update` - UPDATE statement
    * `:delete` - DELETE statement
    * `:other` - Any other SQL command (DDL, etc.)
  """
  @type command_type :: :select | :insert | :update | :delete | :other

  @typedoc """
  The result structure returned from query execution.
  """
  @type t :: %__MODULE__{
          command: command_type() | nil,
          columns: [String.t()] | nil,
          rows: [[term()]] | nil,
          num_rows: non_neg_integer()
        }

  @doc """
  Creates a new Result struct from the given options.

  ## Options

    * `:command` - The command type (defaults to `:other`)
    * `:columns` - List of column names (defaults to `nil`)
    * `:rows` - List of rows (defaults to `nil`)
    * `:num_rows` - Number of rows (defaults to `0`)

  ## Examples

      iex> EctoLibSql.Result.new(command: :insert, num_rows: 1)
      %EctoLibSql.Result{command: :insert, num_rows: 1}

      iex> EctoLibSql.Result.new(command: :select, columns: ["id"], rows: [[1], [2]], num_rows: 2)
      %EctoLibSql.Result{command: :select, columns: ["id"], rows: [[1], [2]], num_rows: 2}

  """
  @spec new(keyword()) :: t()
  def new(options) do
    %__MODULE__{
      command: Keyword.get(options, :command, :other),
      columns: Keyword.get(options, :columns),
      rows: Keyword.get(options, :rows),
      num_rows: Keyword.get(options, :num_rows, 0)
    }
  end
end
