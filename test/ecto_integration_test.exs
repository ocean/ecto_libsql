defmodule Ecto.Integration.EctoLibSqlTest do
  use ExUnit.Case, async: false

  # Define test modules for Ecto schemas and repo
  defmodule TestRepo do
    use Ecto.Repo,
      otp_app: :ecto_libsql,
      adapter: Ecto.Adapters.LibSql
  end

  defmodule User do
    use Ecto.Schema
    import Ecto.Changeset

    schema "users" do
      field(:name, :string)
      field(:email, :string)
      field(:age, :integer)
      field(:active, :boolean, default: true)
      field(:balance, :decimal)
      field(:bio, :string)

      has_many(:posts, Ecto.Integration.EctoLibSqlTest.Post)

      timestamps()
    end

    def changeset(user, attrs) do
      user
      |> cast(attrs, [:name, :email, :age, :active, :balance, :bio])
      |> validate_required([:name, :email])
      |> validate_format(:email, ~r/@/)
      |> unique_constraint(:email, name: "users_email_index")
    end
  end

  defmodule Post do
    use Ecto.Schema
    import Ecto.Changeset

    schema "posts" do
      field(:title, :string)
      field(:body, :string)
      field(:published, :boolean, default: false)
      field(:view_count, :integer, default: 0)
      field(:published_at, :naive_datetime)

      belongs_to(:user, Ecto.Integration.EctoLibSqlTest.User)

      timestamps()
    end

    def changeset(post, attrs) do
      post
      |> cast(attrs, [:title, :body, :published, :view_count, :published_at, :user_id])
      |> validate_required([:title, :body])
    end
  end

  @test_db "z_ecto_libsql_test-ecto_integration.db"

  setup_all do
    # Start the test repo
    {:ok, _} = TestRepo.start_link(database: @test_db)

    # Create tables
    Ecto.Adapters.SQL.query!(TestRepo, """
    CREATE TABLE IF NOT EXISTS users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      email TEXT NOT NULL UNIQUE,
      age INTEGER,
      active INTEGER DEFAULT 1,
      balance DECIMAL,
      bio TEXT,
      inserted_at DATETIME,
      updated_at DATETIME
    )
    """)

    Ecto.Adapters.SQL.query!(TestRepo, """
    CREATE TABLE IF NOT EXISTS posts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL,
      body TEXT,
      published INTEGER DEFAULT 0,
      view_count INTEGER DEFAULT 0,
      published_at DATETIME,
      user_id INTEGER,
      inserted_at DATETIME,
      updated_at DATETIME,
      FOREIGN KEY (user_id) REFERENCES users(id)
    )
    """)

    on_exit(fn ->
      EctoLibSql.TestHelpers.cleanup_db_files(@test_db)
    end)

    :ok
  end

  setup do
    # Clean tables before each test
    Ecto.Adapters.SQL.query!(TestRepo, "DELETE FROM posts")
    Ecto.Adapters.SQL.query!(TestRepo, "DELETE FROM users")
    :ok
  end

  describe "basic CRUD operations" do
    test "insert and retrieve a user" do
      user = %User{
        name: "Alice",
        email: "alice@example.com",
        age: 30,
        balance: Decimal.new("100.50")
      }

      {:ok, inserted_user} = TestRepo.insert(user)

      assert inserted_user.id != nil
      assert inserted_user.name == "Alice"
      assert inserted_user.email == "alice@example.com"
      assert inserted_user.age == 30
      assert inserted_user.active == true

      # Retrieve the user
      retrieved_user = TestRepo.get(User, inserted_user.id)
      assert retrieved_user.name == "Alice"
      assert retrieved_user.email == "alice@example.com"
    end

    test "update a user" do
      {:ok, user} = TestRepo.insert(%User{name: "Bob", email: "bob@example.com", age: 25})

      {:ok, updated_user} =
        user
        |> Ecto.Changeset.change(age: 26)
        |> TestRepo.update()

      assert updated_user.age == 26

      # Verify in database
      retrieved = TestRepo.get(User, user.id)
      assert retrieved.age == 26
    end

    test "delete a user" do
      {:ok, user} = TestRepo.insert(%User{name: "Charlie", email: "charlie@example.com"})

      {:ok, _deleted} = TestRepo.delete(user)

      assert TestRepo.get(User, user.id) == nil
    end

    test "get_by finds user by email" do
      {:ok, _user} = TestRepo.insert(%User{name: "Dave", email: "dave@example.com"})

      found = TestRepo.get_by(User, email: "dave@example.com")
      assert found != nil
      assert found.name == "Dave"
    end
  end

  describe "queries" do
    test "list all users" do
      TestRepo.insert(%User{name: "Alice", email: "alice@example.com"})
      TestRepo.insert(%User{name: "Bob", email: "bob@example.com"})
      TestRepo.insert(%User{name: "Charlie", email: "charlie@example.com"})

      users = TestRepo.all(User)
      assert length(users) == 3
    end

    test "filter users by age" do
      TestRepo.insert(%User{name: "Alice", email: "alice@example.com", age: 20})
      TestRepo.insert(%User{name: "Bob", email: "bob@example.com", age: 30})
      TestRepo.insert(%User{name: "Charlie", email: "charlie@example.com", age: 25})

      import Ecto.Query

      users =
        User
        |> where([u], u.age > 22)
        |> order_by([u], asc: u.age)
        |> TestRepo.all()

      assert length(users) == 2
      assert hd(users).name == "Charlie"
    end

    test "count users" do
      TestRepo.insert(%User{name: "Alice", email: "alice@example.com"})
      TestRepo.insert(%User{name: "Bob", email: "bob@example.com"})

      import Ecto.Query

      count =
        User
        |> select([u], count(u.id))
        |> TestRepo.one()

      assert count == 2
    end

    test "find users with LIKE" do
      TestRepo.insert(%User{name: "Alice Smith", email: "alice@example.com"})
      TestRepo.insert(%User{name: "Bob Jones", email: "bob@example.com"})
      TestRepo.insert(%User{name: "Alice Jones", email: "alice.jones@example.com"})

      import Ecto.Query

      users =
        User
        |> where([u], like(u.name, ^"%Alice%"))
        |> TestRepo.all()

      assert length(users) == 2
    end
  end

  describe "associations" do
    test "create post with user association" do
      {:ok, user} = TestRepo.insert(%User{name: "Alice", email: "alice@example.com"})

      post = %Post{
        title: "My First Post",
        body: "Hello, World!",
        user_id: user.id
      }

      {:ok, inserted_post} = TestRepo.insert(post)

      assert inserted_post.user_id == user.id
    end

    test "preload user posts" do
      {:ok, user} = TestRepo.insert(%User{name: "Alice", email: "alice@example.com"})

      TestRepo.insert(%Post{title: "Post 1", body: "Body 1", user_id: user.id})
      TestRepo.insert(%Post{title: "Post 2", body: "Body 2", user_id: user.id})

      user_with_posts =
        User
        |> TestRepo.get(user.id)
        |> TestRepo.preload(:posts)

      assert length(user_with_posts.posts) == 2
    end

    test "build association" do
      {:ok, user} = TestRepo.insert(%User{name: "Bob", email: "bob@example.com"})

      {:ok, post} =
        user
        |> Ecto.build_assoc(:posts)
        |> Post.changeset(%{title: "Associated Post", body: "Test"})
        |> TestRepo.insert()

      assert post.user_id == user.id
    end
  end

  describe "transactions" do
    test "successful transaction commits changes" do
      {:ok, {user, post}} =
        TestRepo.transaction(fn ->
          {:ok, user} = TestRepo.insert(%User{name: "Alice", email: "alice@example.com"})
          {:ok, post} = TestRepo.insert(%Post{title: "Post", body: "Body", user_id: user.id})
          {user, post}
        end)

      # Verify both were committed
      assert TestRepo.get(User, user.id) != nil
      assert TestRepo.get(Post, post.id) != nil
    end

    test "failed transaction rolls back changes" do
      # When a constraint violation occurs without a changeset constraint,
      # Ecto raises ConstraintError. The transaction should still rollback.
      assert_raise Ecto.ConstraintError, fn ->
        TestRepo.transaction(fn ->
          {:ok, _user} = TestRepo.insert(%User{name: "Alice", email: "alice@example.com"})

          # This should cause a unique constraint violation
          TestRepo.insert(%User{name: "Bob", email: "alice@example.com"})
        end)
      end

      # Verify nothing was committed (transaction was rolled back)
      assert TestRepo.all(User) == []
    end

    test "explicit rollback" do
      result =
        TestRepo.transaction(fn ->
          {:ok, user} = TestRepo.insert(%User{name: "Alice", email: "alice@example.com"})

          TestRepo.rollback(:custom_error)

          user
        end)

      assert {:error, :custom_error} = result

      # Verify rollback happened
      assert TestRepo.all(User) == []
    end
  end

  describe "batch operations" do
    test "insert_all" do
      users_data = [
        %{
          name: "Alice",
          email: "alice@example.com",
          inserted_at: ~N[2024-01-01 00:00:00],
          updated_at: ~N[2024-01-01 00:00:00]
        },
        %{
          name: "Bob",
          email: "bob@example.com",
          inserted_at: ~N[2024-01-01 00:00:00],
          updated_at: ~N[2024-01-01 00:00:00]
        },
        %{
          name: "Charlie",
          email: "charlie@example.com",
          inserted_at: ~N[2024-01-01 00:00:00],
          updated_at: ~N[2024-01-01 00:00:00]
        }
      ]

      {3, _} = TestRepo.insert_all(User, users_data)

      assert length(TestRepo.all(User)) == 3
    end

    test "insert_all with returning option" do
      users_data = [
        %{
          name: "ReturnAlice",
          email: "ret-alice@example.com",
          inserted_at: ~N[2024-01-01 00:00:00],
          updated_at: ~N[2024-01-01 00:00:00]
        },
        %{
          name: "ReturnBob",
          email: "ret-bob@example.com",
          inserted_at: ~N[2024-01-01 00:00:00],
          updated_at: ~N[2024-01-01 00:00:00]
        }
      ]

      {count, returned_rows} = TestRepo.insert_all(User, users_data, returning: [:id, :name])

      assert count == 2
      assert length(returned_rows) == 2

      # Check that we got valid IDs back
      [first, second] = returned_rows
      assert first.id != nil
      assert first.name == "ReturnAlice"
      assert second.id != nil
      assert second.name == "ReturnBob"
    end

    test "update_all" do
      TestRepo.insert(%User{name: "Alice", email: "alice@example.com", active: true})
      TestRepo.insert(%User{name: "Bob", email: "bob@example.com", active: true})

      import Ecto.Query

      {2, _} =
        User
        |> where([u], u.active == true)
        |> TestRepo.update_all(set: [active: false])

      inactive_count =
        User
        |> where([u], u.active == false)
        |> TestRepo.aggregate(:count)

      assert inactive_count == 2
    end

    test "delete_all" do
      TestRepo.insert(%User{name: "Alice", email: "alice@example.com", age: 20})
      TestRepo.insert(%User{name: "Bob", email: "bob@example.com", age: 30})
      TestRepo.insert(%User{name: "Charlie", email: "charlie@example.com", age: 25})

      import Ecto.Query

      {2, _} =
        User
        |> where([u], u.age >= 25)
        |> TestRepo.delete_all()

      assert length(TestRepo.all(User)) == 1
    end
  end

  describe "type handling" do
    test "boolean fields work correctly" do
      {:ok, user} =
        TestRepo.insert(%User{name: "Alice", email: "alice@example.com", active: false})

      retrieved = TestRepo.get(User, user.id)
      assert retrieved.active == false
    end

    test "datetime fields work correctly" do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      {:ok, post} =
        TestRepo.insert(%Post{
          title: "Test",
          body: "Body",
          published_at: now
        })

      retrieved = TestRepo.get(Post, post.id)
      assert NaiveDateTime.compare(retrieved.published_at, now) == :eq
    end

    test "decimal fields work correctly" do
      {:ok, user} =
        TestRepo.insert(%User{
          name: "Alice",
          email: "alice@example.com",
          balance: Decimal.new("123.45")
        })

      retrieved = TestRepo.get(User, user.id)
      assert Decimal.equal?(retrieved.balance, Decimal.new("123.45"))
    end

    test "text fields work correctly" do
      long_text = String.duplicate("a", 10000)

      {:ok, user} =
        TestRepo.insert(%User{
          name: "Alice",
          email: "alice@example.com",
          bio: long_text
        })

      retrieved = TestRepo.get(User, user.id)
      assert retrieved.bio == long_text
    end
  end

  describe "constraints" do
    test "unique constraint on email" do
      {:ok, _user} = TestRepo.insert(%User{name: "Alice", email: "alice@example.com"})

      {:error, changeset} =
        %User{name: "Bob", email: "alice@example.com"}
        |> User.changeset(%{})
        |> TestRepo.insert()

      assert %{email: ["has already been taken"]} = errors_on(changeset)
    end

    test "not null constraint" do
      {:error, changeset} =
        %User{}
        |> User.changeset(%{age: 30})
        |> TestRepo.insert()

      errors = errors_on(changeset)
      assert errors[:name]
      assert errors[:email]
    end
  end

  describe "streaming" do
    test "stream large result sets" do
      # Insert many records
      users_data =
        for i <- 1..100 do
          %{
            name: "User #{i}",
            email: "user#{i}@example.com",
            inserted_at: ~N[2024-01-01 00:00:00],
            updated_at: ~N[2024-01-01 00:00:00]
          }
        end

      TestRepo.insert_all(User, users_data)

      # Stream and count
      {:ok, count} =
        TestRepo.transaction(fn ->
          User
          |> TestRepo.stream()
          |> Enum.reduce(0, fn _user, acc -> acc + 1 end)
        end)

      assert count == 100
    end
  end

  describe "binary_id autogeneration and storage" do
    defmodule Document do
      use Ecto.Schema
      import Ecto.Changeset

      @primary_key {:id, :binary_id, autogenerate: true}
      @foreign_key_type :binary_id

      schema "documents" do
        field(:title, :string)
        field(:content, :binary)

        timestamps()
      end

      def changeset(document, attrs) do
        document
        |> cast(attrs, [:title, :content])
        |> validate_required([:title])
      end
    end

    setup do
      # Create table with binary_id primary key and binary content field
      Ecto.Adapters.SQL.query!(TestRepo, """
      CREATE TABLE IF NOT EXISTS documents (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        content BLOB,
        inserted_at DATETIME,
        updated_at DATETIME
      )
      """)

      on_exit(fn ->
        Ecto.Adapters.SQL.query!(TestRepo, "DROP TABLE IF EXISTS documents")
      end)

      :ok
    end

    test "autogenerates binary_id as string UUID" do
      changeset = Document.changeset(%Document{}, %{title: "Test Doc"})
      {:ok, document} = TestRepo.insert(changeset)

      # Verify ID is a string UUID
      assert is_binary(document.id)
      assert String.length(document.id) == 36
      assert document.id =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

      # Verify it was stored in the database correctly
      retrieved = TestRepo.get(Document, document.id)
      assert retrieved.id == document.id
      assert retrieved.title == "Test Doc"
    end

    test "inserts and retrieves binary data correctly" do
      binary_content = <<0, 1, 2, 3, 4, 5, 255, 254, 253>>

      changeset =
        Document.changeset(%Document{}, %{title: "Binary Doc", content: binary_content})

      {:ok, document} = TestRepo.insert(changeset)

      # Verify binary content is stored
      assert document.content == binary_content

      # Retrieve and verify
      retrieved = TestRepo.get(Document, document.id)
      assert retrieved.content == binary_content
    end

    test "handles null binary content" do
      changeset = Document.changeset(%Document{}, %{title: "No Content"})
      {:ok, document} = TestRepo.insert(changeset)

      assert document.content == nil

      retrieved = TestRepo.get(Document, document.id)
      assert retrieved.content == nil
    end

    test "updates binary content" do
      initial_content = <<1, 2, 3>>
      changeset = Document.changeset(%Document{}, %{title: "Doc", content: initial_content})
      {:ok, document} = TestRepo.insert(changeset)

      # Update with new binary content
      new_content = <<4, 5, 6, 7, 8>>
      update_changeset = Document.changeset(document, %{content: new_content})
      {:ok, updated} = TestRepo.update(update_changeset)

      assert updated.content == new_content

      # Verify in database
      retrieved = TestRepo.get(Document, document.id)
      assert retrieved.content == new_content
    end

    test "can query documents by binary_id" do
      # Insert multiple documents
      {:ok, doc1} = TestRepo.insert(Document.changeset(%Document{}, %{title: "Doc 1"}))
      {:ok, doc2} = TestRepo.insert(Document.changeset(%Document{}, %{title: "Doc 2"}))
      {:ok, doc3} = TestRepo.insert(Document.changeset(%Document{}, %{title: "Doc 3"}))

      # Query by ID
      retrieved1 = TestRepo.get(Document, doc1.id)
      retrieved2 = TestRepo.get(Document, doc2.id)
      retrieved3 = TestRepo.get(Document, doc3.id)

      assert retrieved1.title == "Doc 1"
      assert retrieved2.title == "Doc 2"
      assert retrieved3.title == "Doc 3"

      # Verify all IDs are different
      assert doc1.id != doc2.id
      assert doc2.id != doc3.id
      assert doc1.id != doc3.id
    end

    test "binary_id works with associations" do
      defmodule Author do
        use Ecto.Schema

        @primary_key {:id, :binary_id, autogenerate: true}

        schema "authors" do
          field(:name, :string)
        end
      end

      defmodule Article do
        use Ecto.Schema

        @primary_key {:id, :binary_id, autogenerate: true}
        @foreign_key_type :binary_id

        schema "articles" do
          field(:title, :string)
          belongs_to(:author, Author, type: :binary_id)
        end
      end

      # Create tables
      Ecto.Adapters.SQL.query!(TestRepo, """
      CREATE TABLE IF NOT EXISTS authors (
        id TEXT PRIMARY KEY,
        name TEXT
      )
      """)

      Ecto.Adapters.SQL.query!(TestRepo, """
      CREATE TABLE IF NOT EXISTS articles (
        id TEXT PRIMARY KEY,
        title TEXT,
        author_id TEXT REFERENCES authors(id)
      )
      """)

      # Insert author
      author_id = Ecto.UUID.generate()

      Ecto.Adapters.SQL.query!(TestRepo, "INSERT INTO authors (id, name) VALUES (?, ?)", [
        author_id,
        "John Doe"
      ])

      # Insert article with foreign key
      article_id = Ecto.UUID.generate()

      Ecto.Adapters.SQL.query!(
        TestRepo,
        "INSERT INTO articles (id, title, author_id) VALUES (?, ?, ?)",
        [article_id, "Great Article", author_id]
      )

      # Query and verify relationship
      result =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          "SELECT title, author_id FROM articles WHERE id = ?",
          [article_id]
        )

      assert result.num_rows == 1
      [[title, retrieved_author_id]] = result.rows
      assert title == "Great Article"
      assert retrieved_author_id == author_id

      # Cleanup
      Ecto.Adapters.SQL.query!(TestRepo, "DROP TABLE IF EXISTS articles")
      Ecto.Adapters.SQL.query!(TestRepo, "DROP TABLE IF EXISTS authors")
    end
  end

  describe "on_conflict with composite unique index" do
    # This test reproduces the bug report scenario
    defmodule Location do
      use Ecto.Schema
      import Ecto.Changeset

      schema "locations" do
        field(:slug, :string)
        field(:parent_slug, :string)
        field(:name, :string)

        timestamps()
      end

      def changeset(location, attrs) do
        location
        |> cast(attrs, [:slug, :parent_slug, :name])
        |> validate_required([:slug, :name])
        |> unique_constraint([:slug, :parent_slug], name: :locations_slug_parent_index)
      end
    end

    setup do
      # Drop index and table to ensure clean state
      Ecto.Adapters.SQL.query!(TestRepo, "DROP INDEX IF EXISTS locations_slug_parent_index")
      Ecto.Adapters.SQL.query!(TestRepo, "DROP TABLE IF EXISTS locations")

      # Create table with composite unique index
      Ecto.Adapters.SQL.query!(TestRepo, """
      CREATE TABLE locations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        slug TEXT NOT NULL,
        parent_slug TEXT,
        name TEXT NOT NULL,
        inserted_at DATETIME,
        updated_at DATETIME
      )
      """)

      Ecto.Adapters.SQL.query!(
        TestRepo,
        "CREATE UNIQUE INDEX IF NOT EXISTS locations_slug_parent_index ON locations (slug, parent_slug)"
      )

      on_exit(fn ->
        Ecto.Adapters.SQL.query!(TestRepo, "DROP INDEX IF EXISTS locations_slug_parent_index")
        Ecto.Adapters.SQL.query!(TestRepo, "DROP TABLE IF EXISTS locations")
      end)

      :ok
    end

    test "insert with on_conflict: :nothing on composite unique index silently ignores duplicates" do
      # First insert - should succeed
      changeset1 =
        %Location{}
        |> Location.changeset(%{slug: "sydney", parent_slug: "au", name: "Sydney"})

      {:ok, location1} =
        TestRepo.insert(changeset1,
          on_conflict: :nothing,
          conflict_target: [:slug, :parent_slug]
        )

      assert location1.id != nil
      assert location1.slug == "sydney"
      assert location1.parent_slug == "au"

      # Second insert with same slug and parent_slug - should be ignored, not raise
      changeset2 =
        %Location{}
        |> Location.changeset(%{slug: "sydney", parent_slug: "au", name: "Sydney Updated"})

      {:ok, _location2} =
        TestRepo.insert(changeset2,
          on_conflict: :nothing,
          conflict_target: [:slug, :parent_slug]
        )

      # The insert returns a struct but without ID since it was ignored
      # Query to verify only one record exists
      count =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          "SELECT COUNT(*) FROM locations WHERE slug = ? AND parent_slug = ?",
          ["sydney", "au"]
        )

      assert [[1]] = count.rows
    end

    test "insert with on_conflict: :replace_all on composite unique index updates existing record" do
      # First insert
      changeset1 =
        %Location{}
        |> Location.changeset(%{slug: "melbourne", parent_slug: "au", name: "Melbourne"})

      {:ok, _location1} =
        TestRepo.insert(changeset1,
          on_conflict: :replace_all,
          conflict_target: [:slug, :parent_slug]
        )

      # Second insert with same slug and parent_slug - should update
      changeset2 =
        %Location{}
        |> Location.changeset(%{
          slug: "melbourne",
          parent_slug: "au",
          name: "Melbourne Updated"
        })

      {:ok, _location2} =
        TestRepo.insert(changeset2,
          on_conflict: :replace_all,
          conflict_target: [:slug, :parent_slug]
        )

      # Query to verify name was updated
      result =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          "SELECT name FROM locations WHERE slug = ? AND parent_slug = ?",
          ["melbourne", "au"]
        )

      assert [["Melbourne Updated"]] = result.rows
    end

    test "different parent_slug allows duplicate slug" do
      # Insert with parent_slug "au"
      changeset1 =
        %Location{}
        |> Location.changeset(%{slug: "portland", parent_slug: "au", name: "Portland AU"})

      {:ok, location1} = TestRepo.insert(changeset1)
      assert location1.id != nil

      # Insert with parent_slug "us" - should succeed as composite key is different
      changeset2 =
        %Location{}
        |> Location.changeset(%{slug: "portland", parent_slug: "us", name: "Portland US"})

      {:ok, location2} = TestRepo.insert(changeset2)
      assert location2.id != nil
      assert location2.id != location1.id

      # Verify both records exist
      count =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          "SELECT COUNT(*) FROM locations WHERE slug = ?",
          ["portland"]
        )

      assert [[2]] = count.rows
    end
  end

  describe "map parameter encoding" do
    test "plain maps are encoded to JSON before passing to NIF" do
      # Create a user
      user = TestRepo.insert!(%User{name: "Alice", email: "alice@example.com"})

      # Test with plain map as parameter (e.g., for metadata/JSON columns)
      metadata = %{
        "tags" => ["elixir", "database"],
        "priority" => 1,
        "nested" => %{"key" => "value"}
      }

      # Execute query with raw map to exercise automatic encoding in Query.encode_param
      result =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          "INSERT INTO posts (title, body, user_id, inserted_at, updated_at) VALUES (?, ?, ?, datetime('now'), datetime('now'))",
          ["Test Post", metadata, user.id]
        )

      # Verify the insert succeeded (automatic encoding worked)
      assert result.num_rows == 1

      # Verify the data was inserted correctly with JSON encoding
      posts = TestRepo.all(Post)
      assert length(posts) == 1
      post = hd(posts)
      assert post.title == "Test Post"

      # Verify the body contains properly encoded JSON
      assert {:ok, decoded} = Jason.decode(post.body)
      assert decoded["tags"] == ["elixir", "database"]
      assert decoded["priority"] == 1
      assert decoded["nested"]["key"] == "value"
    end

    test "nested maps in parameters are encoded" do
      # Test with nested map structure
      complex_data = %{
        "level1" => %{
          "level2" => %{
            "level3" => "deep value"
          }
        },
        "array" => [1, 2, 3],
        "mixed" => ["string", 42, true]
      }

      # Pass raw map to verify adapter's automatic encoding
      result =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          "SELECT ? as data",
          [complex_data]
        )

      assert [[json_str]] = result.rows
      assert {:ok, decoded} = Jason.decode(json_str)
      assert decoded["level1"]["level2"]["level3"] == "deep value"
    end

    test "structs are not encoded as maps" do
      # DateTime structs should be automatically encoded (handled by query.ex encoding)
      now = DateTime.utc_now()

      # Pass raw DateTime struct to verify automatic encoding
      result =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          "SELECT ? as timestamp",
          [now]
        )

      assert [[timestamp_str]] = result.rows
      assert is_binary(timestamp_str)
      # Verify it's a valid ISO8601 string
      assert {:ok, decoded_dt, _offset} = DateTime.from_iso8601(timestamp_str)
      assert decoded_dt.year == now.year
      assert decoded_dt.month == now.month
      assert decoded_dt.day == now.day
    end
  end

  # Helper function to extract errors from changeset
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
