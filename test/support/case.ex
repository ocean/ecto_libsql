defmodule EctoLibSql.Integration.Case do
  @moduledoc false

  use ExUnit.CaseTemplate

  using do
    quote do
      alias EctoLibSql.Integration.TestRepo
    end
  end

  setup do
    :ok
  end
end
