# Example: Using EctoLibSql as an Ecto Adapter
#
# This file demonstrates how to use EctoLibSql with Ecto for schema definition,
# migrations, and queries.

# Step 1: Configure your repository in config/config.exs

# config :my_app, MyApp.Repo,
#   adapter: Ecto.Adapters.EctoLibSql,
#   database: "my_app.db"
#
# # Or for remote Turso:
# config :my_app, MyApp.Repo,
#   adapter: Ecto.Adapters.EctoLibSql,
#   uri: "libsql://your-database.turso.io",
#   auth_token: System.get_env("TURSO_AUTH_TOKEN")
#
# # Or for remote replica (best of both worlds):
# config :my_app, MyApp.Repo,
#   adapter: Ecto.Adapters.EctoLibSql,
#   database: "replica.db",
#   uri: "libsql://your-database.turso.io",
#   auth_token: System.get_env("TURSO_AUTH_TOKEN"),
#   sync: true

# Step 2: Define your Repo module

defmodule MyApp.Repo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.EctoLibSql
end

# Step 3: Define your schemas

defmodule MyApp.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :name, :string
    field :email, :string
    field :age, :integer
    field :active, :boolean, default: true

    has_many :posts, MyApp.Post

    timestamps()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:name, :email, :age, :active])
    |> validate_required([:name, :email])
    |> validate_format(:email, ~r/@/)
    |> unique_constraint(:email)
  end
end

defmodule MyApp.Post do
  use Ecto.Schema
  import Ecto.Changeset

  schema "posts" do
    field :title, :string
    field :body, :text
    field :published, :boolean, default: false
    field :view_count, :integer, default: 0

    belongs_to :user, MyApp.User

    timestamps()
  end

  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body, :published, :view_count, :user_id])
    |> validate_required([:title, :body])
  end
end

# Step 4: Create migrations (in priv/repo/migrations/)
#
# File: priv/repo/migrations/20240101000000_create_users.exs

defmodule MyApp.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :name, :string, null: false
      add :email, :string, null: false
      add :age, :integer
      add :active, :boolean, default: true

      timestamps()
    end

    create unique_index(:users, [:email])
  end
end

# File: priv/repo/migrations/20240101000001_create_posts.exs

defmodule MyApp.Repo.Migrations.CreatePosts do
  use Ecto.Migration

  def change do
    create table(:posts) do
      add :title, :string, null: false
      add :body, :text
      add :published, :boolean, default: false
      add :view_count, :integer, default: 0
      add :user_id, references(:users, on_delete: :delete_all)

      timestamps()
    end

    create index(:posts, [:user_id])
    create index(:posts, [:published])
  end
end

# Step 5: Run migrations
#
# $ mix ecto.create
# $ mix ecto.migrate

# Step 6: Use Ecto queries in your application

defmodule MyApp.Examples do
  import Ecto.Query
  alias MyApp.{Repo, User, Post}

  # Create a user
  def create_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  # Get all users
  def list_users do
    Repo.all(User)
  end

  # Get user by ID with posts preloaded
  def get_user_with_posts(id) do
    User
    |> Repo.get(id)
    |> Repo.preload(:posts)
  end

  # Find users by email
  def find_user_by_email(email) do
    Repo.get_by(User, email: email)
  end

  # Update user
  def update_user(user, attrs) do
    user
    |> User.changeset(attrs)
    |> Repo.update()
  end

  # Delete user
  def delete_user(user) do
    Repo.delete(user)
  end

  # Create a post for a user
  def create_post(user, attrs) do
    user
    |> Ecto.build_assoc(:posts)
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  # Get published posts with user info
  def list_published_posts do
    Post
    |> where([p], p.published == true)
    |> order_by([p], desc: p.inserted_at)
    |> preload(:user)
    |> Repo.all()
  end

  # Search posts by title
  def search_posts(query_string) do
    search_pattern = "%#{query_string}%"

    Post
    |> where([p], like(p.title, ^search_pattern))
    |> Repo.all()
  end

  # Get user post count
  def user_post_count(user_id) do
    Post
    |> where([p], p.user_id == ^user_id)
    |> select([p], count(p.id))
    |> Repo.one()
  end

  # Get top users by post count
  def top_users_by_posts(limit \\ 10) do
    User
    |> join(:left, [u], p in assoc(u, :posts))
    |> group_by([u], u.id)
    |> select([u, p], {u, count(p.id)})
    |> order_by([u, p], desc: count(p.id))
    |> limit(^limit)
    |> Repo.all()
  end

  # Increment view count (demonstrates updates)
  def increment_view_count(post_id) do
    {1, _} =
      Post
      |> where([p], p.id == ^post_id)
      |> Repo.update_all(inc: [view_count: 1])

    :ok
  end

  # Transaction example
  def create_user_with_post(user_attrs, post_attrs) do
    Repo.transaction(fn ->
      with {:ok, user} <- create_user(user_attrs),
           {:ok, post} <- create_post(user, post_attrs) do
        {user, post}
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  # Batch insert example
  def bulk_insert_users(users_attrs) do
    users = Enum.map(users_attrs, fn attrs ->
      %{
        name: attrs.name,
        email: attrs.email,
        age: attrs[:age],
        active: attrs[:active] || true,
        inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second),
        updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      }
    end)

    Repo.insert_all(User, users)
  end

  # Stream large result sets
  def process_all_posts(callback) do
    Repo.transaction(fn ->
      Post
      |> Repo.stream()
      |> Stream.each(callback)
      |> Stream.run()
    end)
  end
end

# Step 7: Usage examples

# Start your repo in your application supervision tree:
# children = [
#   MyApp.Repo
# ]
# Supervisor.start_link(children, strategy: :one_for_one)

# Then use it in your code:
# {:ok, user} = MyApp.Examples.create_user(%{name: "Alice", email: "alice@example.com", age: 30})
# {:ok, post} = MyApp.Examples.create_post(user, %{title: "Hello World", body: "My first post!"})
# users = MyApp.Examples.list_users()
# published = MyApp.Examples.list_published_posts()
