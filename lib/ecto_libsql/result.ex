defmodule EctoLibSql.Result do
  @moduledoc """
  Represents the result of a database query or command.

  This struct contains all information returned from a successful database
  operation, including column names, result rows, and metadata about the
  operation performed.

  ## Fields

  - `:command` - The type of SQL command (`:select`, `:insert`, `:update`, `:delete`, `:create`, `:begin`, `:commit`, `:rollback`, `:pragma`, `:batch`, `:unknown`, `:other`, or `nil`)
  - `:columns` - List of column names (for SELECT queries), or `nil` for write operations
  - `:rows` - List of rows, where each row is a list of values, or `nil` for write operations
  - `:num_rows` - Number of rows affected or returned

  ## Examples

      # SELECT result
      %EctoLibSql.Result{
        command: :select,
        columns: ["id", "name"],
        rows: [[1, "Alice"], [2, "Bob"]],
        num_rows: 2
      }

      # INSERT/UPDATE/DELETE result (without RETURNING)
      %EctoLibSql.Result{
        command: :insert,
        columns: nil,
        rows: nil,
        num_rows: 1
      }

  """

  defstruct command: nil,
            columns: nil,
            rows: nil,
            num_rows: 0

  @typedoc "The type of SQL command that was executed."
  @type command_type ::
          :select
          | :insert
          | :update
          | :delete
          | :batch
          | :create
          | :begin
          | :commit
          | :rollback
          | :pragma
          | :unknown
          | :other
          | nil

  @typedoc "Result struct containing query results."
  @type t :: %__MODULE__{
          command: command_type(),
          columns: [String.t()] | nil,
          rows: [[term()]] | nil,
          num_rows: non_neg_integer()
        }

  @doc """
  Creates a new Result struct from a keyword list of options.

  ## Options

  - `:command` - The command type (default: `:other`)
  - `:columns` - List of column names (default: `nil`)
  - `:rows` - List of rows (default: `nil`)
  - `:num_rows` - Number of rows (default: `0`)

  ## Examples

      iex> EctoLibSql.Result.new(command: :select, columns: ["id"], rows: [[1]], num_rows: 1)
      %EctoLibSql.Result{command: :select, columns: ["id"], rows: [[1]], num_rows: 1}

  """
  @spec new(Keyword.t()) :: t
  def new(options) do
    %__MODULE__{
      command: Keyword.get(options, :command, :other),
      columns: Keyword.get(options, :columns),
      rows: Keyword.get(options, :rows),
      num_rows: Keyword.get(options, :num_rows, 0)
    }
  end
end
