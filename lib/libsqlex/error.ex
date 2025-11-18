defmodule LibSqlEx.Error do
  @moduledoc """
  Represents an error from the LibSQL database.
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
  Extracts constraint information from SQLite error messages.
  """
  def constraint_violation?(%__MODULE__{message: message}) do
    String.contains?(message, "constraint failed")
  end

  def constraint_name(%__MODULE__{message: message}) do
    case Regex.run(~r/constraint failed: (\w+)\.(\w+)/, message) do
      [_, _table, field] -> field
      _ -> nil
    end
  end
end
