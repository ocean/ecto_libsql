defmodule EctoLibSql.Schemas.Account do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias EctoLibSql.Schemas.Product
  alias EctoLibSql.Schemas.User

  schema "accounts" do
    field(:name, :string)
    field(:email, :string)

    timestamps()

    many_to_many(:users, User, join_through: "account_users")
    has_many(:products, Product)
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [:name, :email])
    |> validate_required([:name])
  end
end
