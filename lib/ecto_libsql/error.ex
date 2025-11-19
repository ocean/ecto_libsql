defmodule EctoLibSql.Error do
  @moduledoc """
  Exception raised when a LibSQL database operation fails.

  This exception contains detailed error information from the underlying
  LibSQL/SQLite database, including constraint violation details.

  ## Fields

  - `:message` - Human-readable error message
  - `:sqlite` - Map containing SQLite-specific error details (`:code`, `:message`)
  """

  defexception [:message, :sqlite]

  @type t :: %__MODULE__{
          message: String.t(),
          sqlite: %{
            code: atom(),
            message: String.t()
          }
        }

  @doc """
  Checks if the error is a constraint violation.

  Returns `true` if the error message indicates a constraint failure,
  `false` otherwise.

  ## Examples

      iex> error = %EctoLibSql.Error{message: "constraint failed: users.email"}
      iex> EctoLibSql.Error.constraint_violation?(error)
      true

  """
  def constraint_violation?(%__MODULE__{message: message}) do
    String.contains?(message, "constraint failed")
  end

  @doc """
  Extracts the constraint field name from an error message.

  Returns the field name if a constraint violation pattern is found,
  `nil` otherwise.

  ## Examples

      iex> error = %EctoLibSql.Error{message: "constraint failed: users.email"}
      iex> EctoLibSql.Error.constraint_name(error)
      "email"

  """
  def constraint_name(%__MODULE__{message: message}) do
    case Regex.run(~r/constraint failed: (\w+)\.(\w+)/, message) do
      [_, _table, field] -> field
      _ -> nil
    end
  end
end
