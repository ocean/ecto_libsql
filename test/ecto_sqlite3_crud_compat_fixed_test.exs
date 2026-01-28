defmodule EctoLibSql.EctoSqlite3CrudCompatFixedTest do
  @moduledoc """
  Fixed version of CRUD compatibility tests using local test repo
  """

  use ExUnit.Case, async: false

  defmodule TestRepo do
    use Ecto.Repo, otp_app: :ecto_libsql, adapter: Ecto.Adapters.LibSql
  end

  alias EctoLibSql.Schemas.Account
  alias EctoLibSql.Schemas.Product
  alias EctoLibSql.Schemas.User

  setup_all do
    # Use unique per-run DB filename to avoid cross-run collisions.
    test_db = "z_ecto_libsql_test-crud_fixed_#{System.unique_integer([:positive])}.db"
    {:ok, _} = TestRepo.start_link(database: test_db)

    # Create tables manually to match working test
    Ecto.Adapters.SQL.query!(TestRepo, """
    CREATE TABLE IF NOT EXISTS accounts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT,
      email TEXT,
      inserted_at DATETIME,
      updated_at DATETIME
    )
    """)

    Ecto.Adapters.SQL.query!(TestRepo, """
    CREATE TABLE IF NOT EXISTS users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT,
      custom_id TEXT,
      inserted_at DATETIME,
      updated_at DATETIME
    )
    """)

    Ecto.Adapters.SQL.query!(TestRepo, """
    CREATE TABLE IF NOT EXISTS products (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      account_id INTEGER,
      name TEXT,
      description TEXT,
      external_id TEXT,
      bid BLOB,
      tags TEXT,
      type INTEGER,
      approved_at DATETIME,
      ordered_at DATETIME,
      price TEXT,
      inserted_at DATETIME,
      updated_at DATETIME
    )
    """)

    Ecto.Adapters.SQL.query!(TestRepo, """
    CREATE TABLE IF NOT EXISTS account_users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      account_id INTEGER,
      user_id INTEGER,
      role TEXT,
      inserted_at DATETIME,
      updated_at DATETIME
    )
    """)

    Ecto.Adapters.SQL.query!(TestRepo, """
    CREATE TABLE IF NOT EXISTS settings (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      properties TEXT,
      checksum BLOB
    )
    """)

    on_exit(fn ->
      EctoLibSql.TestHelpers.cleanup_db_files(test_db)
    end)

    :ok
  end

  test "insert user returns populated struct with id" do
    {:ok, user} = TestRepo.insert(%User{name: "Alice"})

    assert user.id != nil, "User ID should not be nil"
    assert user.name == "Alice"
    assert user.inserted_at != nil
    assert user.updated_at != nil
  end

  test "insert account and product" do
    {:ok, account} = TestRepo.insert(%Account{name: "TestAccount"})

    assert account.id != nil

    {:ok, product} =
      TestRepo.insert(%Product{
        name: "TestProduct",
        account_id: account.id
      })

    assert product.id != nil
    assert product.account_id == account.id
  end

  test "query inserted record" do
    {:ok, user} = TestRepo.insert(%User{name: "Bob"})
    assert user.id != nil

    queried = TestRepo.get(User, user.id)
    assert queried.name == "Bob"
  end

  test "update user" do
    {:ok, user} = TestRepo.insert(%User{name: "Charlie"})

    changeset = User.changeset(user, %{name: "Charles"})
    {:ok, updated} = TestRepo.update(changeset)

    assert updated.name == "Charles"
  end

  test "delete user" do
    {:ok, user} = TestRepo.insert(%User{name: "David"})
    {:ok, _} = TestRepo.delete(user)

    assert TestRepo.get(User, user.id) == nil
  end
end
