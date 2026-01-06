defmodule EctoLibSql.ExplainQueryTest do
  @moduledoc """
  Tests for EXPLAIN and EXPLAIN QUERY PLAN support.

  libSQL/SQLite provides two explain modes:
  - EXPLAIN: Low-level bytecode execution plan
  - EXPLAIN QUERY PLAN: High-level query optimisation plan (recommended for debugging)

  This module tests the `Ecto.Adapters.SQL.explain/3` API which calls the adapter's
  `explain_query/4` callback.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  # Define test modules for Ecto schemas and repo
  defmodule TestRepo do
    use Ecto.Repo,
      otp_app: :ecto_libsql,
      adapter: Ecto.Adapters.LibSql
  end

  defmodule User do
    use Ecto.Schema
    import Ecto.Changeset

    schema "explain_users" do
      field(:name, :string)
      field(:email, :string)
      field(:age, :integer)

      has_many(:posts, EctoLibSql.ExplainQueryTest.Post)

      timestamps()
    end

    def changeset(user, attrs) do
      user
      |> cast(attrs, [:name, :email, :age])
      |> validate_required([:name, :email])
    end
  end

  defmodule Post do
    use Ecto.Schema
    import Ecto.Changeset

    schema "explain_posts" do
      field(:title, :string)
      field(:body, :string)

      belongs_to(:user, EctoLibSql.ExplainQueryTest.User)

      timestamps()
    end

    def changeset(post, attrs) do
      post
      |> cast(attrs, [:title, :body, :user_id])
      |> validate_required([:title, :body])
    end
  end

  @test_db "z_ecto_libsql_test-explain.db"

  setup_all do
    # Start the test repo
    {:ok, _} = TestRepo.start_link(database: @test_db)

    # Create tables
    Ecto.Adapters.SQL.query!(TestRepo, """
    CREATE TABLE IF NOT EXISTS explain_users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      email TEXT NOT NULL,
      age INTEGER,
      inserted_at DATETIME,
      updated_at DATETIME
    )
    """)

    Ecto.Adapters.SQL.query!(TestRepo, """
    CREATE TABLE IF NOT EXISTS explain_posts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL,
      body TEXT,
      user_id INTEGER,
      inserted_at DATETIME,
      updated_at DATETIME,
      FOREIGN KEY(user_id) REFERENCES explain_users(id)
    )
    """)

    # Create indexes for better explain output
    Ecto.Adapters.SQL.query!(
      TestRepo,
      "CREATE INDEX IF NOT EXISTS explain_users_email_index ON explain_users(email)"
    )

    Ecto.Adapters.SQL.query!(
      TestRepo,
      "CREATE INDEX IF NOT EXISTS explain_posts_user_id_index ON explain_posts(user_id)"
    )

    on_exit(fn ->
      Ecto.Adapters.SQL.query!(TestRepo, "DROP TABLE IF EXISTS explain_posts")
      Ecto.Adapters.SQL.query!(TestRepo, "DROP TABLE IF EXISTS explain_users")
      GenServer.stop(TestRepo)
    end)

    {:ok, []}
  end

  setup do
    # Clear tables before each test
    TestRepo.delete_all(Post)
    TestRepo.delete_all(User)

    # Create test data
    {:ok, user1} = TestRepo.insert(%User{name: "Alice", email: "alice@example.com", age: 30})
    {:ok, user2} = TestRepo.insert(%User{name: "Bob", email: "bob@example.com", age: 25})
    {:ok, user3} = TestRepo.insert(%User{name: "Charlie", email: "charlie@example.com", age: 35})

    {:ok, _post1} = TestRepo.insert(%Post{title: "First", body: "Content", user_id: user1.id})
    {:ok, _post2} = TestRepo.insert(%Post{title: "Second", body: "Content", user_id: user1.id})
    {:ok, _post3} = TestRepo.insert(%Post{title: "Third", body: "Content", user_id: user2.id})

    {:ok, users: [user1, user2, user3]}
  end

  describe "explain/3 - basic queries" do
    test "returns explain plan for simple SELECT" do
      query = from(u in User, select: u)
      result = Ecto.Adapters.SQL.explain(TestRepo, :all, query)

      assert is_list(result)
      assert length(result) > 0
    end

    test "returns explain plan for WHERE query" do
      query = from(u in User, where: u.age > 25)
      result = Ecto.Adapters.SQL.explain(TestRepo, :all, query)

      assert is_list(result)
      assert length(result) > 0
    end

    test "returns explain plan for ORDER BY query" do
      query = from(u in User, order_by: [desc: u.name])
      result = Ecto.Adapters.SQL.explain(TestRepo, :all, query)

      assert is_list(result)
      assert length(result) > 0
    end

    test "returns explain plan for LIMIT query" do
      query = from(u in User, limit: 10)
      result = Ecto.Adapters.SQL.explain(TestRepo, :all, query)

      assert is_list(result)
      assert length(result) > 0
    end
  end

  describe "explain/3 - join queries" do
    test "returns explain plan for INNER JOIN" do
      query =
        from(p in Post,
          join: u in assoc(p, :user),
          select: {u.name, p.title}
        )

      result = Ecto.Adapters.SQL.explain(TestRepo, :all, query)

      assert is_list(result)
      assert length(result) > 0
    end
  end

  describe "explain/3 - update and delete queries" do
    test "returns explain plan for UPDATE query" do
      query = from(u in User, where: u.age < 30, update: [set: [age: 30]])
      result = Ecto.Adapters.SQL.explain(TestRepo, :update_all, query)

      assert is_list(result)
    end

    test "returns explain plan for DELETE query" do
      query = from(u in User, where: u.age < 25)
      result = Ecto.Adapters.SQL.explain(TestRepo, :delete_all, query)

      assert is_list(result)
    end
  end

  describe "explain/3 - options" do
    test "respects wrap_in_transaction option" do
      query = from(u in User, select: u)

      # With transaction (default)
      result_with_txn =
        Ecto.Adapters.SQL.explain(TestRepo, :all, query, wrap_in_transaction: true)

      assert is_list(result_with_txn)

      # Without transaction
      result_without_txn =
        Ecto.Adapters.SQL.explain(TestRepo, :all, query, wrap_in_transaction: false)

      assert is_list(result_without_txn)

      # Results should be the same
      assert result_with_txn == result_without_txn
    end
  end

  describe "explain output format" do
    test "explain output is a list of maps" do
      query = from(u in User, where: u.age > 25)
      result = Ecto.Adapters.SQL.explain(TestRepo, :all, query)

      assert is_list(result)
      [first | _] = result
      assert is_map(first)
    end

    test "explain with WHERE shows plan" do
      query = from(u in User, where: u.age > 25, select: u.id)
      result = Ecto.Adapters.SQL.explain(TestRepo, :all, query)

      assert is_list(result)
      assert length(result) > 0
    end
  end
end
