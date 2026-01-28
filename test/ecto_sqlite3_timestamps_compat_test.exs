defmodule EctoLibSql.EctoSqlite3TimestampsCompatTest do
  @moduledoc """
  Compatibility tests based on ecto_sqlite3 timestamps test suite.

  These tests ensure that DateTime and NaiveDateTime handling works
  identically to ecto_sqlite3.
  """

  use ExUnit.Case, async: false

  defmodule TestRepo do
    use Ecto.Repo, otp_app: :ecto_libsql, adapter: Ecto.Adapters.LibSql
  end

  alias EctoLibSql.Schemas.Account
  alias EctoLibSql.Schemas.Product

  import Ecto.Query

  @test_db "z_ecto_libsql_test-sqlite3_timestamps_compat.db"

  defmodule UserNaiveDatetime do
    use Ecto.Schema
    import Ecto.Changeset

    schema "users" do
      field(:name, :string)
      timestamps()
    end

    def changeset(struct, attrs) do
      struct
      |> cast(attrs, [:name])
      |> validate_required([:name])
    end
  end

  defmodule UserUtcDatetime do
    use Ecto.Schema
    import Ecto.Changeset

    schema "users" do
      field(:name, :string)
      timestamps(type: :utc_datetime)
    end

    def changeset(struct, attrs) do
      struct
      |> cast(attrs, [:name])
      |> validate_required([:name])
    end
  end

  setup_all do
    # Clean up any existing test database
    EctoLibSql.TestHelpers.cleanup_db_files(@test_db)

    # Configure the repo
    Application.put_env(:ecto_libsql, TestRepo,
      adapter: Ecto.Adapters.LibSql,
      database: @test_db
    )

    {:ok, _} = TestRepo.start_link()

    # Create tables manually with proper timestamp handling
    Ecto.Adapters.SQL.query!(TestRepo, """
    CREATE TABLE IF NOT EXISTS accounts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT,
      email TEXT,
      inserted_at TEXT,
      updated_at TEXT
    )
    """)

    Ecto.Adapters.SQL.query!(TestRepo, """
    CREATE TABLE IF NOT EXISTS users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT,
      custom_id TEXT,
      inserted_at TEXT,
      updated_at TEXT
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
      approved_at TEXT,
      ordered_at TEXT,
      price TEXT,
      inserted_at TEXT,
      updated_at TEXT
    )
    """)

    on_exit(fn ->
      EctoLibSql.TestHelpers.cleanup_db_files(@test_db)
    end)

    :ok
  end

  setup do
    # Clear all tables before each test for proper isolation
    Ecto.Adapters.SQL.query!(TestRepo, "DELETE FROM products", [])
    Ecto.Adapters.SQL.query!(TestRepo, "DELETE FROM accounts", [])
    Ecto.Adapters.SQL.query!(TestRepo, "DELETE FROM users", [])
    :ok
  end

  test "insert and fetch naive datetime" do
    {:ok, user} =
      %UserNaiveDatetime{}
      |> UserNaiveDatetime.changeset(%{name: "Bob"})
      |> TestRepo.insert()

    user =
      UserNaiveDatetime
      |> select([u], u)
      |> where([u], u.id == ^user.id)
      |> TestRepo.one()

    assert user
    assert user.name == "Bob"
    assert user.inserted_at != nil
    assert user.updated_at != nil
  end

  test "insert and fetch utc datetime" do
    {:ok, user} =
      %UserUtcDatetime{}
      |> UserUtcDatetime.changeset(%{name: "Bob"})
      |> TestRepo.insert()

    user =
      UserUtcDatetime
      |> select([u], u)
      |> where([u], u.id == ^user.id)
      |> TestRepo.one()

    assert user
    assert user.name == "Bob"
    assert user.inserted_at != nil
    assert user.updated_at != nil
  end

  test "insert and fetch nil values" do
    now = DateTime.utc_now()

    product =
      insert_product(%{
        name: "Nil Date Test",
        approved_at: now,
        ordered_at: now
      })

    product = TestRepo.get(Product, product.id)
    assert product.name == "Nil Date Test"
    # The datetime should be truncated to second precision
    assert product.approved_at == DateTime.truncate(now, :second) |> DateTime.to_naive()
    assert product.ordered_at == DateTime.truncate(now, :second)

    changeset = Product.changeset(product, %{approved_at: nil, ordered_at: nil})
    assert {:ok, _updated_product} = TestRepo.update(changeset)
    product = TestRepo.get(Product, product.id)
    assert product.approved_at == nil
    assert product.ordered_at == nil
  end

  test "datetime comparisons" do
    account = insert_account(%{name: "Test"})

    insert_product(%{
      account_id: account.id,
      name: "Foo",
      approved_at: ~U[2023-01-01T01:00:00Z]
    })

    insert_product(%{
      account_id: account.id,
      name: "Bar",
      approved_at: ~U[2023-01-01T02:00:00Z]
    })

    insert_product(%{
      account_id: account.id,
      name: "Qux",
      approved_at: ~U[2023-01-01T03:00:00Z]
    })

    since = ~U[2023-01-01T01:59:00Z]

    assert [
             %{name: "Qux"},
             %{name: "Bar"}
           ] =
             Product
             |> select([p], p)
             |> where([p], p.approved_at >= ^since)
             |> order_by([p], desc: p.approved_at)
             |> TestRepo.all()
  end

  @tag :sqlite_limitation
  test "using built in ecto functions with datetime" do
    account = insert_account(%{name: "Test"})

    insert_product(%{
      account_id: account.id,
      name: "Foo",
      inserted_at: seconds_ago(1)
    })

    insert_product(%{
      account_id: account.id,
      name: "Bar",
      inserted_at: seconds_ago(3)
    })

    result =
      Product
      |> select([p], p)
      |> where([p], p.inserted_at >= ago(2, "second"))
      |> order_by([p], desc: p.inserted_at)
      |> TestRepo.all()

    assert [%{name: "Foo"}] = result
  end

  test "max of naive datetime" do
    datetime = ~N[2014-01-16 20:26:51]
    TestRepo.insert!(%UserNaiveDatetime{inserted_at: datetime})
    query = from(p in UserNaiveDatetime, select: max(p.inserted_at))
    assert [^datetime] = TestRepo.all(query)
  end

  test "naive datetime with microseconds" do
    _now_naive = NaiveDateTime.utc_now()

    {:ok, user} =
      %UserNaiveDatetime{}
      |> UserNaiveDatetime.changeset(%{name: "Test"})
      |> TestRepo.insert()

    fetched = TestRepo.get(UserNaiveDatetime, user.id)
    # Inserted_at should be a NaiveDateTime
    assert is_struct(fetched.inserted_at, NaiveDateTime)
  end

  test "utc datetime with microseconds" do
    _now_utc = DateTime.utc_now()

    {:ok, user} =
      %UserUtcDatetime{}
      |> UserUtcDatetime.changeset(%{name: "Test"})
      |> TestRepo.insert()

    fetched = TestRepo.get(UserUtcDatetime, user.id)
    # Inserted_at should be a DateTime
    assert is_struct(fetched.inserted_at, DateTime)
    assert fetched.inserted_at.time_zone == "Etc/UTC"
  end

  defp insert_account(attrs) do
    %Account{}
    |> Account.changeset(attrs)
    |> TestRepo.insert!()
  end

  defp insert_product(attrs) do
    %Product{}
    |> Product.changeset(attrs)
    |> TestRepo.insert!()
  end

  defp seconds_ago(seconds) do
    now = DateTime.utc_now()
    DateTime.add(now, -seconds, :second)
  end
end
