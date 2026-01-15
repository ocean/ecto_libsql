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
    test_db = "z_ecto_libsql_test-migrations_#{:erlang.unique_integer([:positive])}.db"
    {:ok, pid} = start_supervised({TestRepo, database: test_db})

    on_exit(fn ->
      # Stop the repo before cleaning up files.
      if Process.alive?(pid) do
        stop_supervised(TestRepo)
      end

      # Small delay to ensure file handles are released.
      Process.sleep(10)

      EctoLibSql.TestHelpers.cleanup_db_files(test_db)
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

  describe "table options - libSQL extensions" do
    test "creates table with RANDOM ROWID option" do
      table = %Table{name: :sessions, prefix: nil, options: [random_rowid: true]}

      columns = [
        {:add, :token, :string, [null: false]},
        {:add, :user_id, :id, []},
        {:add, :created_at, :utc_datetime, []}
      ]

      [sql] = Connection.execute_ddl({:create, table, columns})

      # Verify RANDOM ROWID appears in the SQL
      assert sql =~ "RANDOM ROWID"

      # Execute the migration
      Ecto.Adapters.SQL.query!(TestRepo, sql)

      # Verify table was created correctly
      {:ok, %{rows: [[schema]]}} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "SELECT sql FROM sqlite_master WHERE type='table' AND name='sessions'"
        )

      assert schema =~ "RANDOM ROWID"
    end

    test "SQL generation includes STRICT when option is set" do
      table = %Table{name: :products, prefix: nil, options: [strict: true]}

      columns = [
        {:add, :id, :id, [primary_key: true]},
        {:add, :name, :string, [null: false]},
        {:add, :price, :float, []},
        {:add, :stock, :integer, []}
      ]

      [sql] = Connection.execute_ddl({:create, table, columns})

      # Verify STRICT appears in the generated SQL
      # Note: Execution may fail on older libSQL versions that don't support STRICT
      assert sql =~ "STRICT"
    end
  end

  describe "generated/computed columns" do
    test "creates table with virtual generated column" do
      table = %Table{name: :users, prefix: nil}

      columns = [
        {:add, :id, :id, [primary_key: true]},
        {:add, :first_name, :string, [null: false]},
        {:add, :last_name, :string, [null: false]},
        {:add, :full_name, :string, [generated: "first_name || ' ' || last_name"]}
      ]

      [sql] = Connection.execute_ddl({:create, table, columns})

      # Verify GENERATED clause appears in SQL (but not STORED)
      assert sql =~ "GENERATED ALWAYS AS"
      assert sql =~ "first_name || ' ' || last_name"
      refute sql =~ "STORED"
    end

    test "creates table with stored generated column" do
      table = %Table{name: :products, prefix: nil}

      columns = [
        {:add, :id, :id, [primary_key: true]},
        {:add, :price, :float, [null: false]},
        {:add, :quantity, :integer, [null: false]},
        {:add, :total_value, :float, [generated: "price * quantity", stored: true]}
      ]

      [sql] = Connection.execute_ddl({:create, table, columns})

      # Verify GENERATED clause with STORED
      assert sql =~ "GENERATED ALWAYS AS"
      assert sql =~ "STORED"
      assert sql =~ "price * quantity"
    end

    test "rejects generated column with default value" do
      table = %Table{name: :users, prefix: nil}

      columns = [
        {:add, :id, :id, [primary_key: true]},
        {:add, :computed, :string, [generated: "some_expr", default: "fallback"]}
      ]

      assert_raise ArgumentError,
                   "generated columns cannot have a DEFAULT value (SQLite constraint)",
                   fn ->
                     Connection.execute_ddl({:create, table, columns})
                   end
    end

    test "rejects generated column as primary key" do
      table = %Table{name: :users, prefix: nil}

      columns = [
        {:add, :computed_id, :integer, [primary_key: true, generated: "rowid * 1000"]}
      ]

      assert_raise ArgumentError,
                   "generated columns cannot be part of a PRIMARY KEY (SQLite constraint)",
                   fn ->
                     Connection.execute_ddl({:create, table, columns})
                   end
    end
  end

  describe "column_default edge cases" do
    test "handles nil default" do
      table = %Table{name: :users, prefix: nil}
      columns = [{:add, :name, :string, [default: nil]}]

      [sql] = Connection.execute_ddl({:create, table, columns})

      # nil should result in no DEFAULT clause
      refute sql =~ "DEFAULT"
    end

    test "handles boolean defaults" do
      table = %Table{name: :users, prefix: nil}

      columns = [
        {:add, :active, :boolean, [default: true]},
        {:add, :deleted, :boolean, [default: false]}
      ]

      [sql] = Connection.execute_ddl({:create, table, columns})

      # Booleans should map to 1/0
      assert sql =~ ~r/"active".*INTEGER DEFAULT 1/
      assert sql =~ ~r/"deleted".*INTEGER DEFAULT 0/
    end

    test "handles string defaults" do
      table = %Table{name: :users, prefix: nil}
      columns = [{:add, :status, :string, [default: "pending"]}]

      [sql] = Connection.execute_ddl({:create, table, columns})

      assert sql =~ "DEFAULT 'pending'"
    end

    test "handles numeric defaults" do
      table = %Table{name: :users, prefix: nil}

      columns = [
        {:add, :count, :integer, [default: 0]},
        {:add, :rating, :float, [default: 5.0]}
      ]

      [sql] = Connection.execute_ddl({:create, table, columns})

      assert sql =~ ~r/"count".*INTEGER DEFAULT 0/
      assert sql =~ ~r/"rating".*REAL DEFAULT 5\.0/
    end

    test "handles fragment defaults" do
      table = %Table{name: :users, prefix: nil}
      columns = [{:add, :created_at, :string, [default: {:fragment, "datetime('now')"}]}]

      [sql] = Connection.execute_ddl({:create, table, columns})

      assert sql =~ "DEFAULT datetime('now')"
    end

    test "handles unexpected types gracefully (empty map)" do
      # This test verifies the catch-all clause for unexpected types.
      # Empty maps can come from some migrations or other third-party code.
      table = %Table{name: :users, prefix: nil}
      columns = [{:add, :metadata, :string, [default: %{}]}]

      # Should not raise FunctionClauseError.
      [sql] = Connection.execute_ddl({:create, table, columns})

      # Empty map should be treated as no default.
      assert sql =~ ~r/"metadata".*TEXT/
      refute sql =~ ~r/"metadata".*DEFAULT/
    end

    test "handles unexpected types gracefully (list)" do
      # Lists are another unexpected type that might appear.
      table = %Table{name: :users, prefix: nil}
      columns = [{:add, :tags, :string, [default: []]}]

      # Should not raise FunctionClauseError.
      [sql] = Connection.execute_ddl({:create, table, columns})

      # Empty list should be treated as no default.
      assert sql =~ ~r/"tags".*TEXT/
      refute sql =~ ~r/"tags".*DEFAULT/
    end

    test "handles unexpected types gracefully (atom)" do
      # Atoms other than booleans might appear as defaults.
      table = %Table{name: :users, prefix: nil}
      columns = [{:add, :status, :string, [default: :unknown]}]

      # Should not raise FunctionClauseError.
      [sql] = Connection.execute_ddl({:create, table, columns})

      # Unexpected atom should be treated as no default.
      assert sql =~ ~r/"status".*TEXT/
      refute sql =~ ~r/"status".*DEFAULT/
    end
  end

  describe "CHECK constraints" do
    test "creates table with column-level CHECK constraint" do
      table = %Table{name: :users, prefix: nil}

      columns = [
        {:add, :id, :id, [primary_key: true]},
        {:add, :age, :integer, [check: "age >= 0"]}
      ]

      [sql] = Connection.execute_ddl({:create, table, columns})
      Ecto.Adapters.SQL.query!(TestRepo, sql)

      # Verify table was created with CHECK constraint.
      {:ok, %{rows: [[schema]]}} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "SELECT sql FROM sqlite_master WHERE type='table' AND name='users'"
        )

      assert schema =~ "CHECK (age >= 0)"
    end

    test "enforces column-level CHECK constraint" do
      table = %Table{name: :users, prefix: nil}

      columns = [
        {:add, :id, :id, [primary_key: true]},
        {:add, :age, :integer, [check: "age >= 0"]}
      ]

      [sql] = Connection.execute_ddl({:create, table, columns})
      Ecto.Adapters.SQL.query!(TestRepo, sql)

      # Valid insert should succeed.
      {:ok, _} = Ecto.Adapters.SQL.query(TestRepo, "INSERT INTO users (age) VALUES (?)", [25])

      # Invalid insert should fail.
      assert {:error, %EctoLibSql.Error{message: message}} =
               Ecto.Adapters.SQL.query(TestRepo, "INSERT INTO users (age) VALUES (?)", [-5])

      assert message =~ "CHECK constraint failed"
    end

    test "raises error when attempting to use create constraint DDL" do
      alias Ecto.Migration.Constraint

      assert_raise ArgumentError,
                   ~r/LibSQL\/SQLite does not support ALTER TABLE ADD CONSTRAINT/,
                   fn ->
                     Connection.execute_ddl(
                       {:create,
                        %Constraint{
                          name: "age_check",
                          table: "users",
                          check: "age >= 0"
                        }}
                     )
                   end
    end

    test "raises error when attempting to use drop constraint DDL" do
      alias Ecto.Migration.Constraint

      assert_raise ArgumentError,
                   ~r/LibSQL\/SQLite does not support ALTER TABLE DROP CONSTRAINT/,
                   fn ->
                     Connection.execute_ddl(
                       {:drop,
                        %Constraint{
                          name: "age_check",
                          table: "users"
                        }, :restrict}
                     )
                   end
    end

    test "raises error when attempting to use drop_if_exists constraint DDL" do
      alias Ecto.Migration.Constraint

      assert_raise ArgumentError,
                   ~r/LibSQL\/SQLite does not support ALTER TABLE DROP CONSTRAINT/,
                   fn ->
                     Connection.execute_ddl(
                       {:drop_if_exists,
                        %Constraint{
                          name: "age_check",
                          table: "users"
                        }, :restrict}
                     )
                   end
    end

    test "creates table with multiple CHECK constraints" do
      table = %Table{name: :jobs, prefix: nil}

      columns = [
        {:add, :id, :id, [primary_key: true]},
        {:add, :attempt, :integer, [default: 0, null: false, check: "attempt >= 0"]},
        {:add, :max_attempts, :integer, [default: 20, null: false, check: "max_attempts > 0"]},
        {:add, :priority, :integer, [default: 0, null: false, check: "priority BETWEEN 0 AND 9"]}
      ]

      [sql] = Connection.execute_ddl({:create, table, columns})
      Ecto.Adapters.SQL.query!(TestRepo, sql)

      # Verify table was created with all CHECK constraints.
      {:ok, %{rows: [[schema]]}} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "SELECT sql FROM sqlite_master WHERE type='table' AND name='jobs'"
        )

      assert schema =~ "CHECK (attempt >= 0)"
      assert schema =~ "CHECK (max_attempts > 0)"
      assert schema =~ "CHECK (priority BETWEEN 0 AND 9)"
    end

    test "enforces multiple CHECK constraints correctly" do
      table = %Table{name: :jobs, prefix: nil}

      columns = [
        {:add, :id, :id, [primary_key: true]},
        {:add, :attempt, :integer, [default: 0, null: false, check: "attempt >= 0"]},
        {:add, :max_attempts, :integer, [default: 20, null: false, check: "max_attempts > 0"]},
        {:add, :priority, :integer, [default: 0, null: false, check: "priority BETWEEN 0 AND 9"]}
      ]

      [sql] = Connection.execute_ddl({:create, table, columns})
      Ecto.Adapters.SQL.query!(TestRepo, sql)

      # Valid insert should succeed.
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO jobs (attempt, max_attempts, priority) VALUES (?, ?, ?)",
          [0, 20, 5]
        )

      # Invalid attempt (negative) should fail.
      assert {:error, %EctoLibSql.Error{message: message}} =
               Ecto.Adapters.SQL.query(
                 TestRepo,
                 "INSERT INTO jobs (attempt, max_attempts, priority) VALUES (?, ?, ?)",
                 [-1, 20, 5]
               )

      assert message =~ "CHECK constraint failed"

      # Invalid max_attempts (zero) should fail.
      assert {:error, %EctoLibSql.Error{message: message}} =
               Ecto.Adapters.SQL.query(
                 TestRepo,
                 "INSERT INTO jobs (attempt, max_attempts, priority) VALUES (?, ?, ?)",
                 [0, 0, 5]
               )

      assert message =~ "CHECK constraint failed"

      # Invalid priority (out of range) should fail.
      assert {:error, %EctoLibSql.Error{message: message}} =
               Ecto.Adapters.SQL.query(
                 TestRepo,
                 "INSERT INTO jobs (attempt, max_attempts, priority) VALUES (?, ?, ?)",
                 [0, 20, 10]
               )

      assert message =~ "CHECK constraint failed"
    end

    test "raises error when :check option is not a binary string" do
      table = %Table{name: :users, prefix: nil}

      columns = [
        {:add, :id, :id, [primary_key: true]},
        {:add, :age, :integer, [check: 123]}
      ]

      assert_raise ArgumentError,
                   ~r/CHECK constraint expression must be a binary string, got: 123/,
                   fn ->
                     Connection.execute_ddl({:create, table, columns})
                   end
    end
  end
end
