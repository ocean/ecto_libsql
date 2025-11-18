defmodule Ecto.Adapters.LibSqlEx.ConnectionTest do
  use ExUnit.Case, async: true

  alias Ecto.Adapters.LibSqlEx.Connection
  alias Ecto.Migration.{Table, Index}

  describe "DDL generation" do
    test "creates table with columns" do
      table = %Table{name: :users, prefix: nil}

      columns = [
        {:add, :id, :id, [primary_key: true]},
        {:add, :name, :string, []},
        {:add, :age, :integer, []},
        {:add, :active, :boolean, [default: true]}
      ]

      [sql] = Connection.execute_ddl({:create, table, columns})

      assert sql =~ ~s(CREATE TABLE "users")
      assert sql =~ ~s("id" INTEGER PRIMARY KEY)
      assert sql =~ ~s("name" TEXT)
      assert sql =~ ~s("age" INTEGER)
      assert sql =~ ~s("active" INTEGER DEFAULT 1)
    end

    test "creates table with IF NOT EXISTS" do
      table = %Table{name: :users, prefix: nil}
      columns = [{:add, :id, :id, [primary_key: true]}]

      [sql] = Connection.execute_ddl({:create_if_not_exists, table, columns})

      assert sql =~ "CREATE TABLE IF NOT EXISTS"
    end

    test "creates table with composite primary key" do
      table = %Table{name: :user_roles, prefix: nil}

      columns = [
        {:add, :user_id, :integer, [primary_key: true]},
        {:add, :role_id, :integer, [primary_key: true]}
      ]

      [sql] = Connection.execute_ddl({:create, table, columns})

      assert sql =~ ~s[PRIMARY KEY ("user_id", "role_id")]
    end

    test "creates table with NOT NULL constraint" do
      table = %Table{name: :users, prefix: nil}

      columns = [
        {:add, :email, :string, [null: false]}
      ]

      [sql] = Connection.execute_ddl({:create, table, columns})

      assert sql =~ ~s("email" TEXT NOT NULL)
    end

    test "creates table with default values" do
      table = %Table{name: :posts, prefix: nil}

      columns = [
        {:add, :title, :string, [default: "Untitled"]},
        {:add, :count, :integer, [default: 0]},
        {:add, :published, :boolean, [default: false]}
      ]

      [sql] = Connection.execute_ddl({:create, table, columns})

      assert sql =~ ~s("title" TEXT DEFAULT 'Untitled')
      assert sql =~ ~s("count" INTEGER DEFAULT 0)
      assert sql =~ ~s("published" INTEGER DEFAULT 0)
    end

    test "drops table" do
      table = %Table{name: :users, prefix: nil}

      [sql] = Connection.execute_ddl({:drop, table, []})

      assert sql == ~s(DROP TABLE "users")
    end

    test "drops table with IF EXISTS" do
      table = %Table{name: :users, prefix: nil}

      [sql] = Connection.execute_ddl({:drop_if_exists, table, []})

      assert sql == ~s(DROP TABLE IF EXISTS "users")
    end

    test "alters table to add column" do
      table = %Table{name: :users, prefix: nil}
      changes = [{:add, :bio, :text, []}]

      [sql] = Connection.execute_ddl({:alter, table, changes})

      assert sql == ~s(ALTER TABLE "users" ADD COLUMN "bio" TEXT)
    end

    test "raises on column modification" do
      table = %Table{name: :users, prefix: nil}
      changes = [{:modify, :age, :string, []}]

      assert_raise ArgumentError, ~r/ALTER COLUMN is not supported/, fn ->
        Connection.execute_ddl({:alter, table, changes})
      end
    end

    test "raises on column removal" do
      table = %Table{name: :users, prefix: nil}
      changes = [{:remove, :age, :integer, []}]

      assert_raise ArgumentError, ~r/DROP COLUMN/, fn ->
        Connection.execute_ddl({:alter, table, changes})
      end
    end

    test "creates index" do
      index = %Index{
        name: :users_email_index,
        table: :users,
        columns: [:email],
        unique: false,
        where: nil
      }

      [sql] = Connection.execute_ddl({:create, index})

      assert sql == ~s[CREATE INDEX "users_email_index" ON "users" ("email")]
    end

    test "creates unique index" do
      index = %Index{
        name: :users_email_index,
        table: :users,
        columns: [:email],
        unique: true,
        where: nil
      }

      [sql] = Connection.execute_ddl({:create, index})

      assert sql =~ "CREATE UNIQUE INDEX"
    end

    test "creates index with IF NOT EXISTS" do
      index = %Index{
        name: :users_email_index,
        table: :users,
        columns: [:email],
        unique: false,
        where: nil
      }

      [sql] = Connection.execute_ddl({:create_if_not_exists, index})

      assert sql =~ "IF NOT EXISTS"
    end

    test "creates partial index with WHERE clause" do
      index = %Index{
        name: :active_users_index,
        table: :users,
        columns: [:email],
        unique: false,
        where: "active = 1"
      }

      [sql] = Connection.execute_ddl({:create, index})

      assert sql =~ " WHERE active = 1"
    end

    test "creates composite index" do
      index = %Index{
        name: :users_name_email_index,
        table: :users,
        columns: [:name, :email],
        unique: false,
        where: nil
      }

      [sql] = Connection.execute_ddl({:create, index})

      assert sql =~ ~s[("name", "email")]
    end

    test "drops index" do
      index = %Index{name: :users_email_index, table: :users, columns: [:email]}

      [sql] = Connection.execute_ddl({:drop, index, []})

      assert sql == ~s(DROP INDEX "users_email_index")
    end

    test "drops index with IF EXISTS" do
      index = %Index{name: :users_email_index, table: :users, columns: [:email]}

      [sql] = Connection.execute_ddl({:drop_if_exists, index, []})

      assert sql == ~s(DROP INDEX IF EXISTS "users_email_index")
    end

    test "renames column" do
      table = %Table{name: :users, prefix: nil}

      [sql] = Connection.execute_ddl({:rename, table, :old_name, :new_name})

      assert sql == ~s(ALTER TABLE "users" RENAME COLUMN "old_name" TO "new_name")
    end

    test "renames table" do
      old_table = %Table{name: :old_users, prefix: nil}
      new_table = %Table{name: :new_users, prefix: nil}

      [sql] = Connection.execute_ddl({:rename, old_table, new_table})

      assert sql == ~s(ALTER TABLE "old_users" RENAME TO "new_users")
    end
  end

  describe "column types" do
    test "maps Ecto types to SQLite types correctly" do
      test_cases = [
        {:id, "INTEGER"},
        {:binary_id, "TEXT"},
        {:uuid, "TEXT"},
        {:string, "TEXT"},
        {:binary, "BLOB"},
        {:integer, "INTEGER"},
        {:float, "REAL"},
        {:boolean, "INTEGER"},
        {:text, "TEXT"},
        {:date, "DATE"},
        {:time, "TIME"},
        {:naive_datetime, "DATETIME"},
        {:utc_datetime, "DATETIME"},
        {:decimal, "DECIMAL"}
      ]

      for {ecto_type, sqlite_type} <- test_cases do
        table = %Table{name: :test, prefix: nil}
        columns = [{:add, :col, ecto_type, []}]
        [sql] = Connection.execute_ddl({:create, table, columns})

        assert sql =~ sqlite_type,
               "Expected #{ecto_type} to map to #{sqlite_type}, but got: #{sql}"
      end
    end

    test "raises on array types" do
      table = %Table{name: :test, prefix: nil}
      columns = [{:add, :tags, {:array, :string}, []}]

      assert_raise ArgumentError, ~r/does not support array types/, fn ->
        Connection.execute_ddl({:create, table, columns})
      end
    end
  end

  describe "table_exists_query" do
    test "generates correct query" do
      {sql, params} = Connection.table_exists_query("users")

      assert sql == "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1 LIMIT 1"
      assert params == ["users"]
    end
  end

  describe "constraint conversion" do
    test "converts UNIQUE constraint errors" do
      error = %{message: "UNIQUE constraint failed: users.email"}
      constraints = Connection.to_constraints(error, [])

      # Returns string constraint names to match Ecto changeset format
      assert [unique: "email"] = constraints
    end

    test "converts FOREIGN KEY constraint errors" do
      error = %{message: "FOREIGN KEY constraint failed"}
      constraints = Connection.to_constraints(error, [])

      assert [foreign_key: :unknown] = constraints
    end

    test "converts CHECK constraint errors" do
      error = %{message: "CHECK constraint failed: positive_age"}
      constraints = Connection.to_constraints(error, [])

      # Returns string constraint names to match Ecto changeset format
      assert [check: "positive_age"] = constraints
    end

    test "returns empty list for non-constraint errors" do
      error = %{message: "Some other error"}
      constraints = Connection.to_constraints(error, [])

      assert [] = constraints
    end
  end
end
