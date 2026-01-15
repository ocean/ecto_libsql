defmodule EctoLibSql.Schemas.AccountUser do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias EctoLibSql.Schemas.Account
  alias EctoLibSql.Schemas.User

  schema "account_users" do
    field(:role, :string)
    belongs_to(:account, Account)
    belongs_to(:user, User)

    timestamps()
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [:account_id, :user_id, :role])
    |> validate_required([:account_id, :user_id])
  end
end
