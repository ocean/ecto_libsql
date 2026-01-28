defmodule EctoLibSql.Integration.TestRepo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :ecto_libsql,
    adapter: Ecto.Adapters.LibSql
end
