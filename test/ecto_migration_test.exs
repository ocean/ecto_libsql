defmodule Ecto.Adapters.LibSql.MigrationTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.LibSql.Connection
  alias Ecto.Migration.{Table, Reference, Index}

  # Test repo for running actual migrations.
  defmodule TestRepo do
    use Ecto.Repo,
      otp_app: :ecto_libsql,
      adapter: Ecto.Adapters.LibSql
  end

  setup do
    # Start a fresh repo for each test with a unique database file.
    test_db = "test_migrations_#{:erlang.unique_integer([:positive])}.db"
    {:ok, _} = start_supervised({TestRepo, database: test_db})

    on_exit(fn ->
      File.rm(test_db)
    end)

    # Foreign keys are disabled by default in SQLite - tests that need them will enable them explicitly.

    :ok
  end

  describe "basic table creation with references" do
    test "creates table with foreign key reference" do
      # Create parent table.
      Ecto.Adapters.SQL.query!(TestRepo, """
      CREATE TABLE users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL
      )
      """)

      # Create child table using migrations API.
      table = %Table{name: :posts, prefix: nil}

      columns = [
        {:add, :id, :id, [primary_key: true]},
        {:add, :title, :string, [null: false]},
        {:add, :user_id, %Reference{table: :users, column: :id, type: :integer}, []}
      ]

      [sql] = Connection.execute_ddl({:create, table, columns})
      Ecto.Adapters.SQL.query!(TestRepo, sql)

      # Verify table was created correctly.
      {:ok, %{rows: [[schema]]}} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "SELECT sql FROM sqlite_master WHERE type='table' AND name='posts'"
        )

      assert schema =~ "REFERENCES"
      assert schema =~ "users"
    end

    test "creates many-to-many join table with binary_id references" do
      # Create parent tables.
      Ecto.Adapters.SQL.query!(TestRepo, """
      CREATE TABLE places (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL
      )
      """)

      Ecto.Adapters.SQL.query!(TestRepo, """
      CREATE TABLE place_types (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL
      )
      """)

      # Create join table.
      table = %Table{name: :places_place_types, prefix: nil, options: [primary_key: false]}

      columns = [
        {:add, :place_id,
         %Reference{
           table: :places,
           column: :id,
           type: :binary_id,
           on_delete: :delete_all
         }, [null: false]},
        {:add, :place_type_id,
         %Reference{
           table: :place_types,
           column: :id,
           type: :binary_id,
           on_delete: :delete_all
         }, [null: false]}
      ]

      [sql] = Connection.execute_ddl({:create, table, columns})
      Ecto.Adapters.SQL.query!(TestRepo, sql)

      # Insert test data to verify foreign keys work.
      Ecto.Adapters.SQL.query!(
        TestRepo,
        "INSERT INTO places (id, name) VALUES ('place-1', 'Sydney')"
      )

      Ecto.Adapters.SQL.query!(
        TestRepo,
        "INSERT INTO place_types (id, name) VALUES ('type-1', 'City')"
      )

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO places_place_types (place_id, place_type_id) VALUES ('place-1', 'type-1')"
        )

      # Verify join was created.
      {:ok, %{num_rows: count}} =
        Ecto.Adapters.SQL.query(TestRepo, "SELECT COUNT(*) FROM places_place_types")

      assert count == 1
    end

    test "creates table with multiple foreign keys" do
      # Create parent tables.
      Ecto.Adapters.SQL.query!(TestRepo, """
      CREATE TABLE users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL
      )
      """)

      Ecto.Adapters.SQL.query!(TestRepo, """
      CREATE TABLE categories (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL
      )
      """)

      # Create table with multiple foreign keys.
      table = %Table{name: :posts, prefix: nil}

      columns = [
        {:add, :id, :id, [primary_key: true]},
        {:add, :title, :string, [null: false]},
        {:add, :author_id, %Reference{table: :users, column: :id, type: :integer}, []},
        {:add, :editor_id, %Reference{table: :users, column: :id, type: :integer}, []},
        {:add, :category_id, %Reference{table: :categories, column: :id, type: :integer}, []}
      ]

      [sql] = Connection.execute_ddl({:create, table, columns})
      Ecto.Adapters.SQL.query!(TestRepo, sql)

      # Verify schema.
      {:ok, %{rows: [[schema]]}} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "SELECT sql FROM sqlite_master WHERE type='table' AND name='posts'"
        )

      assert schema =~ ~s["author_id"]
      assert schema =~ ~s["editor_id"]
      assert schema =~ ~s["category_id"]
      # Should have 3 REFERENCES clauses.
      assert schema |> String.split("REFERENCES") |> length() == 4
    end
  end

  describe "foreign key cascade behaviours" do
    test "on_delete :delete_all cascades deletes" do
      # Create tables.
      Ecto.Adapters.SQL.query!(TestRepo, """
      CREATE TABLE users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL
      )
      """)

      table = %Table{name: :posts, prefix: nil}

      columns = [
        {:add, :id, :id, [primary_key: true]},
        {:add, :title, :string, []},
        {:add, :user_id,
         %Reference{
           table: :users,
           column: :id,
           type: :integer,
           on_delete: :delete_all
         }, []}
      ]

      [sql] = Connection.execute_ddl({:create, table, columns})
      Ecto.Adapters.SQL.query!(TestRepo, sql)

      # Enable foreign keys for this test.
      Ecto.Adapters.SQL.query!(TestRepo, "PRAGMA foreign_keys = ON")

      # Insert test data.
      {:ok, %{rows: [[user_id]]}} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO users (name) VALUES ('Alice') RETURNING id"
        )

      Ecto.Adapters.SQL.query!(
        TestRepo,
        "INSERT INTO posts (title, user_id) VALUES ('Post 1', #{user_id})"
      )

      Ecto.Adapters.SQL.query!(
        TestRepo,
        "INSERT INTO posts (title, user_id) VALUES ('Post 2', #{user_id})"
      )

      # Verify posts exist.
      {:ok, %{rows: [[post_count]]}} =
        Ecto.Adapters.SQL.query(TestRepo, "SELECT COUNT(*) FROM posts")

      assert post_count == 2

      # Delete the user - should cascade to posts.
      Ecto.Adapters.SQL.query!(TestRepo, "DELETE FROM users WHERE id = #{user_id}")

      # Verify posts were deleted.
      {:ok, %{rows: [[post_count_after]]}} =
        Ecto.Adapters.SQL.query(TestRepo, "SELECT COUNT(*) FROM posts")

      assert post_count_after == 0
    end

    test "on_delete :nilify_all sets foreign key to NULL" do
      # Create tables.
      Ecto.Adapters.SQL.query!(TestRepo, """
      CREATE TABLE users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL
      )
      """)

      table = %Table{name: :posts, prefix: nil}

      columns = [
        {:add, :id, :id, [primary_key: true]},
        {:add, :title, :string, []},
        {:add, :user_id,
         %Reference{
           table: :users,
           column: :id,
           type: :integer,
           on_delete: :nilify_all
         }, []}
      ]

      [sql] = Connection.execute_ddl({:create, table, columns})
      Ecto.Adapters.SQL.query!(TestRepo, sql)

      # Enable foreign keys.
      Ecto.Adapters.SQL.query!(TestRepo, "PRAGMA foreign_keys = ON")

      # Insert test data.
      {:ok, %{rows: [[user_id]]}} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO users (name) VALUES ('Bob') RETURNING id"
        )

      Ecto.Adapters.SQL.query!(
        TestRepo,
        "INSERT INTO posts (title, user_id) VALUES ('Post 1', #{user_id})"
      )

      # Delete the user - should set user_id to NULL.
      Ecto.Adapters.SQL.query!(TestRepo, "DELETE FROM users WHERE id = #{user_id}")

      # Verify post still exists but user_id is NULL.
      {:ok, %{rows: [[title, nil]]}} =
        Ecto.Adapters.SQL.query(TestRepo, "SELECT title, user_id FROM posts")

      assert title == "Post 1"
    end

    test "on_delete :restrict prevents deletion" do
      # Create tables.
      Ecto.Adapters.SQL.query!(TestRepo, """
      CREATE TABLE users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL
      )
      """)

      table = %Table{name: :posts, prefix: nil}

      columns = [
        {:add, :id, :id, [primary_key: true]},
        {:add, :title, :string, []},
        {:add, :user_id,
         %Reference{
           table: :users,
           column: :id,
           type: :integer,
           on_delete: :restrict
         }, [null: false]}
      ]

      [sql] = Connection.execute_ddl({:create, table, columns})
      Ecto.Adapters.SQL.query!(TestRepo, sql)

      # Enable foreign keys.
      Ecto.Adapters.SQL.query!(TestRepo, "PRAGMA foreign_keys = ON")

      # Insert test data.
      {:ok, %{rows: [[user_id]]}} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO users (name) VALUES ('Charlie') RETURNING id"
        )

      Ecto.Adapters.SQL.query!(
        TestRepo,
        "INSERT INTO posts (title, user_id) VALUES ('Post 1', #{user_id})"
      )

      # Try to delete the user - should fail.
      assert {:error, %EctoLibSql.Error{message: message}} =
               Ecto.Adapters.SQL.query(TestRepo, "DELETE FROM users WHERE id = #{user_id}")

      assert message =~ "FOREIGN KEY constraint failed"

      # Verify user still exists.
      {:ok, %{num_rows: user_count}} =
        Ecto.Adapters.SQL.query(TestRepo, "SELECT COUNT(*) FROM users")

      assert user_count == 1
    end
  end

  describe "foreign key update behaviours" do
    test "on_update :update_all cascades updates" do
      # Create tables with updatable primary key.
      Ecto.Adapters.SQL.query!(TestRepo, """
      CREATE TABLE users (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL
      )
      """)

      table = %Table{name: :posts, prefix: nil}

      columns = [
        {:add, :id, :id, [primary_key: true]},
        {:add, :title, :string, []},
        {:add, :user_id,
         %Reference{
           table: :users,
           column: :id,
           type: :binary_id,
           on_update: :update_all
         }, []}
      ]

      [sql] = Connection.execute_ddl({:create, table, columns})
      Ecto.Adapters.SQL.query!(TestRepo, sql)

      # Enable foreign keys.
      Ecto.Adapters.SQL.query!(TestRepo, "PRAGMA foreign_keys = ON")

      # Insert test data.
      Ecto.Adapters.SQL.query!(
        TestRepo,
        "INSERT INTO users (id, name) VALUES ('user-1', 'Dave')"
      )

      Ecto.Adapters.SQL.query!(
        TestRepo,
        "INSERT INTO posts (title, user_id) VALUES ('Post 1', 'user-1')"
      )

      # Update the user's ID.
      Ecto.Adapters.SQL.query!(
        TestRepo,
        "UPDATE users SET id = 'user-2' WHERE id = 'user-1'"
      )

      # Verify post's user_id was updated.
      {:ok, %{rows: [[user_id]]}} =
        Ecto.Adapters.SQL.query(TestRepo, "SELECT user_id FROM posts")

      assert user_id == "user-2"
    end
  end

  describe "composite primary keys with references" do
    test "creates join table with composite primary key" do
      # Create parent tables.
      Ecto.Adapters.SQL.query!(TestRepo, """
      CREATE TABLE users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL
      )
      """)

      Ecto.Adapters.SQL.query!(TestRepo, """
      CREATE TABLE roles (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL
      )
      """)

      # Create join table with composite PK.
      table = %Table{name: :user_roles, prefix: nil}

      columns = [
        {:add, :user_id,
         %Reference{
           table: :users,
           column: :id,
           type: :integer,
           on_delete: :delete_all
         }, [null: false, primary_key: true]},
        {:add, :role_id,
         %Reference{
           table: :roles,
           column: :id,
           type: :integer,
           on_delete: :delete_all
         }, [null: false, primary_key: true]},
        {:add, :granted_at, :naive_datetime, []}
      ]

      [sql] = Connection.execute_ddl({:create, table, columns})
      Ecto.Adapters.SQL.query!(TestRepo, sql)

      # Verify schema has composite primary key.
      {:ok, %{rows: [[table_schema]]}} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "SELECT sql FROM sqlite_master WHERE type='table' AND name='user_roles'"
        )

      assert table_schema =~ ~s[PRIMARY KEY ("user_id", "role_id")]
      assert table_schema =~ "REFERENCES"
    end
  end

  describe "altering tables with references" do
    test "adds column with foreign key reference to existing table" do
      # Create initial table.
      Ecto.Adapters.SQL.query!(TestRepo, """
      CREATE TABLE posts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL
      )
      """)

      # Create referenced table.
      Ecto.Adapters.SQL.query!(TestRepo, """
      CREATE TABLE users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL
      )
      """)

      # Add foreign key column.
      table = %Table{name: :posts, prefix: nil}

      changes = [
        {:add, :user_id, %Reference{table: :users, column: :id, type: :integer}, []}
      ]

      [sql] = Connection.execute_ddl({:alter, table, changes})
      Ecto.Adapters.SQL.query!(TestRepo, sql)

      # Verify the column exists by inserting data.
      Ecto.Adapters.SQL.query!(
        TestRepo,
        "INSERT INTO users (name) VALUES ('Test User')"
      )

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO posts (title, user_id) VALUES ('Test Post', 1)"
        )

      {:ok, %{rows: [[user_id]]}} =
        Ecto.Adapters.SQL.query(TestRepo, "SELECT user_id FROM posts")

      assert user_id == 1
    end
  end

  describe "indexes on foreign key columns" do
    test "creates index on foreign key column" do
      # Create tables.
      Ecto.Adapters.SQL.query!(TestRepo, """
      CREATE TABLE users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL
      )
      """)

      table = %Table{name: :posts, prefix: nil}

      columns = [
        {:add, :id, :id, [primary_key: true]},
        {:add, :title, :string, []},
        {:add, :user_id, %Reference{table: :users, column: :id, type: :integer}, []}
      ]

      [create_table_sql] = Connection.execute_ddl({:create, table, columns})
      Ecto.Adapters.SQL.query!(TestRepo, create_table_sql)

      # Create index on foreign key.
      index = %Index{
        name: :posts_user_id_index,
        table: :posts,
        columns: [:user_id],
        unique: false
      }

      [create_index_sql] = Connection.execute_ddl({:create, index})
      Ecto.Adapters.SQL.query!(TestRepo, create_index_sql)

      # Verify index was created.
      {:ok, %{rows: indexes}} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='posts'"
        )

      index_names = Enum.map(indexes, fn [name] -> name end)
      assert "posts_user_id_index" in index_names
    end

    test "creates unique index on foreign key for one-to-one relationship" do
      # Create tables.
      Ecto.Adapters.SQL.query!(TestRepo, """
      CREATE TABLE users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL
      )
      """)

      table = %Table{name: :user_profiles, prefix: nil}

      columns = [
        {:add, :id, :id, [primary_key: true]},
        {:add, :bio, :text, []},
        {:add, :user_id,
         %Reference{
           table: :users,
           column: :id,
           type: :integer,
           on_delete: :delete_all
         }, [null: false]}
      ]

      [create_table_sql] = Connection.execute_ddl({:create, table, columns})
      Ecto.Adapters.SQL.query!(TestRepo, create_table_sql)

      # Create unique index for one-to-one relationship.
      index = %Index{
        name: :user_profiles_user_id_index,
        table: :user_profiles,
        columns: [:user_id],
        unique: true
      }

      [create_index_sql] = Connection.execute_ddl({:create, index})
      Ecto.Adapters.SQL.query!(TestRepo, create_index_sql)

      # Test uniqueness constraint.
      Ecto.Adapters.SQL.query!(
        TestRepo,
        "INSERT INTO users (name) VALUES ('Eve')"
      )

      Ecto.Adapters.SQL.query!(
        TestRepo,
        "INSERT INTO user_profiles (bio, user_id) VALUES ('Bio 1', 1)"
      )

      # Second profile for same user should fail.
      assert {:error, _} =
               Ecto.Adapters.SQL.query(
                 TestRepo,
                 "INSERT INTO user_profiles (bio, user_id) VALUES ('Bio 2', 1)"
               )
    end
  end

  describe "self-referential foreign keys" do
    test "creates table with self-referential foreign key" do
      # Create table with parent_id referencing itself.
      table = %Table{name: :categories, prefix: nil}

      columns = [
        {:add, :id, :id, [primary_key: true]},
        {:add, :name, :string, [null: false]},
        {:add, :parent_id,
         %Reference{
           table: :categories,
           column: :id,
           type: :integer,
           on_delete: :nilify_all
         }, []}
      ]

      [sql] = Connection.execute_ddl({:create, table, columns})
      Ecto.Adapters.SQL.query!(TestRepo, sql)

      # Insert test data.
      {:ok, %{rows: [[parent_id]]}} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO categories (name) VALUES ('Electronics') RETURNING id"
        )

      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO categories (name, parent_id) VALUES ('Computers', #{parent_id})"
        )

      # Verify hierarchy.
      {:ok, %{rows: [[child_name, ^parent_id]]}} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "SELECT name, parent_id FROM categories WHERE name = 'Computers'"
        )

      assert child_name == "Computers"
    end
  end

  describe "edge cases and error handling" do
    test "handles reference with nil column (defaults to :id)" do
      Ecto.Adapters.SQL.query!(TestRepo, """
      CREATE TABLE users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL
      )
      """)

      table = %Table{name: :posts, prefix: nil}

      # Reference without explicit column should default to :id.
      columns = [
        {:add, :id, :id, [primary_key: true]},
        {:add, :user_id, %Reference{table: :users, column: nil, type: :integer}, []}
      ]

      [sql] = Connection.execute_ddl({:create, table, columns})

      # Should reference the id column by default.
      assert sql =~ ~s[REFERENCES "users"("id")]

      Ecto.Adapters.SQL.query!(TestRepo, sql)
    end

    test "creates table with reference to custom primary key column" do
      # Create table with custom primary key name.
      Ecto.Adapters.SQL.query!(TestRepo, """
      CREATE TABLE users (
        user_uuid TEXT PRIMARY KEY,
        name TEXT NOT NULL
      )
      """)

      table = %Table{name: :posts, prefix: nil}

      columns = [
        {:add, :id, :id, [primary_key: true]},
        {:add, :author_uuid,
         %Reference{
           table: :users,
           column: :user_uuid,
           type: :binary_id
         }, []}
      ]

      [sql] = Connection.execute_ddl({:create, table, columns})

      assert sql =~ ~s[REFERENCES "users"("user_uuid")]

      Ecto.Adapters.SQL.query!(TestRepo, sql)
    end

    test "combines NOT NULL constraint with foreign key" do
      Ecto.Adapters.SQL.query!(TestRepo, """
      CREATE TABLE users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL
      )
      """)

      table = %Table{name: :posts, prefix: nil}

      columns = [
        {:add, :id, :id, [primary_key: true]},
        {:add, :user_id,
         %Reference{
           table: :users,
           column: :id,
           type: :integer
         }, [null: false]}
      ]

      [sql] = Connection.execute_ddl({:create, table, columns})

      assert sql =~ "NOT NULL"
      assert sql =~ "REFERENCES"

      Ecto.Adapters.SQL.query!(TestRepo, sql)

      # Verify NOT NULL constraint works.
      assert {:error, _} =
               Ecto.Adapters.SQL.query(
                 TestRepo,
                 "INSERT INTO posts (user_id) VALUES (NULL)"
               )
    end

    test "creates multiple references in single migration" do
      # Create all parent tables.
      Ecto.Adapters.SQL.query!(TestRepo, "CREATE TABLE users (id INTEGER PRIMARY KEY)")

      Ecto.Adapters.SQL.query!(TestRepo, "CREATE TABLE categories (id INTEGER PRIMARY KEY)")

      Ecto.Adapters.SQL.query!(TestRepo, "CREATE TABLE tags (id INTEGER PRIMARY KEY)")

      # Create table with multiple foreign keys in one migration.
      table = %Table{name: :posts, prefix: nil}

      columns = [
        {:add, :id, :id, [primary_key: true]},
        {:add, :title, :string, [null: false]},
        {:add, :user_id, %Reference{table: :users, type: :integer}, []},
        {:add, :category_id, %Reference{table: :categories, type: :integer}, []},
        {:add, :tag_id, %Reference{table: :tags, type: :integer}, []}
      ]

      [sql] = Connection.execute_ddl({:create, table, columns})
      Ecto.Adapters.SQL.query!(TestRepo, sql)

      # Verify all references exist.
      {:ok, %{rows: [[schema]]}} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "SELECT sql FROM sqlite_master WHERE type='table' AND name='posts'"
        )

      assert schema =~ ~s[REFERENCES "users"]
      assert schema =~ ~s[REFERENCES "categories"]
      assert schema =~ ~s[REFERENCES "tags"]
    end
  end
end
