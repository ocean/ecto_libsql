defmodule EctoLibSql.ExistsQueryTest do
  @moduledoc """
  Tests for Repo.exists?/2 functionality.

  This test reproduces a bug where `Repo.exists?` generated invalid SQL
  with an empty SELECT clause: `SELECT  FROM "users"` instead of
  `SELECT 1 FROM "users"`.

  The fix adds a clause to handle empty field lists:
  `defp select_fields(%{fields: []}, _sources, _query), do: "1"`
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  defmodule TestRepo do
    use Ecto.Repo,
      otp_app: :ecto_libsql,
      adapter: Ecto.Adapters.LibSql
  end

  defmodule User do
    use Ecto.Schema

    schema "users" do
      field(:name, :string)
      field(:age, :integer)
    end
  end

  @test_db "z_ecto_libsql_test-exists_query.db"

  setup_all do
    {:ok, _} = TestRepo.start_link(database: @test_db)

    Ecto.Adapters.SQL.query!(TestRepo, """
    CREATE TABLE IF NOT EXISTS users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      age INTEGER
    )
    """)

    on_exit(fn ->
      EctoLibSql.TestHelpers.cleanup_db_files(@test_db)
    end)

    :ok
  end

  setup do
    Ecto.Adapters.SQL.query!(TestRepo, "DELETE FROM users")
    :ok
  end

  describe "Repo.exists?/2" do
    test "returns false when no records match the query" do
      result = TestRepo.exists?(from(u in User, where: u.age > 25))
      assert result == false
    end

    test "returns true when records match the query" do
      Ecto.Adapters.SQL.query!(TestRepo, "INSERT INTO users (name, age) VALUES ('Alice', 30)")

      result = TestRepo.exists?(from(u in User, where: u.age > 25))
      assert result == true
    end

    test "works with simple table query without where clause" do
      assert TestRepo.exists?(User) == false

      Ecto.Adapters.SQL.query!(TestRepo, "INSERT INTO users (name, age) VALUES ('Bob', 20)")

      assert TestRepo.exists?(User) == true
    end

    test "works with complex where clauses" do
      Ecto.Adapters.SQL.query!(TestRepo, "INSERT INTO users (name, age) VALUES ('Alice', 30)")
      Ecto.Adapters.SQL.query!(TestRepo, "INSERT INTO users (name, age) VALUES ('Bob', 20)")
      Ecto.Adapters.SQL.query!(TestRepo, "INSERT INTO users (name, age) VALUES ('Charlie', 35)")

      # Multiple conditions
      result =
        TestRepo.exists?(
          from(u in User,
            where: u.age > 25 and u.name != "Alice"
          )
        )

      assert result == true

      # No matches
      result =
        TestRepo.exists?(
          from(u in User,
            where: u.age > 100
          )
        )

      assert result == false
    end

    test "works inside transactions" do
      TestRepo.transaction(fn ->
        assert TestRepo.exists?(User) == false

        Ecto.Adapters.SQL.query!(TestRepo, "INSERT INTO users (name, age) VALUES ('Dave', 25)")

        assert TestRepo.exists?(User) == true
        assert TestRepo.exists?(from(u in User, where: u.age == 25)) == true
        assert TestRepo.exists?(from(u in User, where: u.age == 30)) == false
      end)
    end
  end

  describe "workaround pattern (for documentation)" do
    test "count-based alternative approach still works" do
      Ecto.Adapters.SQL.query!(TestRepo, "INSERT INTO users (name, age) VALUES ('Alice', 30)")

      # The workaround pattern
      has_records? =
        User
        |> where([u], u.age > 25)
        |> select([u], count(u.id))
        |> TestRepo.one()
        |> Kernel.>(0)

      assert has_records? == true

      # Should match exists? behaviour
      assert TestRepo.exists?(from(u in User, where: u.age > 25)) == has_records?
    end
  end
end
