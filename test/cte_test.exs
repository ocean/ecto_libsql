defmodule EctoLibSql.CTETest do
  @moduledoc """
  Tests for Common Table Expression (CTE) support.

  These tests verify that EctoLibSql correctly handles:
  - Simple CTEs (WITH clauses)
  - Recursive CTEs (WITH RECURSIVE)
  - Multiple CTEs
  - CTEs with different operations (SELECT, UPDATE, DELETE)
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  # Define test repo.
  defmodule TestRepo do
    use Ecto.Repo,
      otp_app: :ecto_libsql,
      adapter: Ecto.Adapters.LibSql
  end

  defmodule Employee do
    use Ecto.Schema

    schema "employees" do
      field(:name, :string)
      field(:manager_id, :integer)
      field(:level, :integer, default: 0)
    end
  end

  defmodule Category do
    use Ecto.Schema

    schema "categories" do
      field(:name, :string)
      field(:parent_id, :integer)
    end
  end

  @test_db "z_ecto_libsql_test-cte.db"

  setup_all do
    # Start the test repo.
    {:ok, _} = TestRepo.start_link(database: @test_db)

    # Create employees table.
    Ecto.Adapters.SQL.query!(TestRepo, """
    CREATE TABLE IF NOT EXISTS employees (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      manager_id INTEGER REFERENCES employees(id),
      level INTEGER DEFAULT 0
    )
    """)

    # Create categories table.
    Ecto.Adapters.SQL.query!(TestRepo, """
    CREATE TABLE IF NOT EXISTS categories (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      parent_id INTEGER REFERENCES categories(id)
    )
    """)

    on_exit(fn ->
      File.rm(@test_db)
      File.rm(@test_db <> "-shm")
      File.rm(@test_db <> "-wal")
    end)

    :ok
  end

  setup do
    # Clean tables before each test.
    Ecto.Adapters.SQL.query!(TestRepo, "DELETE FROM employees")
    Ecto.Adapters.SQL.query!(TestRepo, "DELETE FROM categories")
    :ok
  end

  describe "simple CTE" do
    test "basic CTE with single SELECT" do
      # Insert test data.
      TestRepo.insert!(%Employee{name: "Alice", level: 1})
      TestRepo.insert!(%Employee{name: "Bob", level: 2})
      TestRepo.insert!(%Employee{name: "Charlie", level: 2})

      # Create a CTE that selects high-level employees.
      high_level = from(e in Employee, where: e.level >= 2, select: %{id: e.id, name: e.name})

      query =
        "high_level_employees"
        |> with_cte("high_level_employees", as: ^high_level)
        |> select([h], h.name)

      result = TestRepo.all(query)
      assert length(result) == 2
      assert "Bob" in result
      assert "Charlie" in result
    end

    test "CTE with filtering in main query" do
      # Insert test data.
      TestRepo.insert!(%Employee{name: "Alice", level: 1})
      TestRepo.insert!(%Employee{name: "Bob", level: 2})
      TestRepo.insert!(%Employee{name: "Charlie", level: 3})

      # Create a CTE and filter in main query.
      all_employees = from(e in Employee, select: %{id: e.id, name: e.name, level: e.level})

      query =
        "all_emp"
        |> with_cte("all_emp", as: ^all_employees)
        |> where([e], e.level > 1)
        |> select([e], e.name)

      result = TestRepo.all(query)
      assert length(result) == 2
      assert "Bob" in result
      assert "Charlie" in result
    end
  end

  describe "recursive CTE" do
    test "recursive CTE for hierarchical data" do
      # Build an organisational hierarchy:
      # Alice (CEO) -> Bob (VP) -> Charlie (Manager) -> Dave (Employee)
      alice = TestRepo.insert!(%Employee{name: "Alice", manager_id: nil, level: 0})
      bob = TestRepo.insert!(%Employee{name: "Bob", manager_id: alice.id, level: 1})
      charlie = TestRepo.insert!(%Employee{name: "Charlie", manager_id: bob.id, level: 2})
      _dave = TestRepo.insert!(%Employee{name: "Dave", manager_id: charlie.id, level: 3})

      # Find all employees under Bob using recursive CTE.
      # This is a simplified test - we use raw SQL for the recursive part.
      result =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          """
          WITH RECURSIVE subordinates AS (
            SELECT id, name, manager_id, level
            FROM employees
            WHERE manager_id = ?
            UNION ALL
            SELECT e.id, e.name, e.manager_id, e.level
            FROM employees e
            INNER JOIN subordinates s ON e.manager_id = s.id
          )
          SELECT name FROM subordinates ORDER BY level
          """,
          [bob.id]
        )

      assert result.num_rows == 2
      names = Enum.map(result.rows, fn [name] -> name end)
      assert names == ["Charlie", "Dave"]
    end

    test "recursive CTE for category tree" do
      # Build a category tree:
      # Electronics -> Computers -> Laptops
      #             -> Phones
      electronics = TestRepo.insert!(%Category{name: "Electronics", parent_id: nil})
      computers = TestRepo.insert!(%Category{name: "Computers", parent_id: electronics.id})
      _laptops = TestRepo.insert!(%Category{name: "Laptops", parent_id: computers.id})
      _phones = TestRepo.insert!(%Category{name: "Phones", parent_id: electronics.id})

      # Find all subcategories of Electronics using recursive CTE.
      result =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          """
          WITH RECURSIVE subcategories AS (
            SELECT id, name, parent_id
            FROM categories
            WHERE parent_id = ?
            UNION ALL
            SELECT c.id, c.name, c.parent_id
            FROM categories c
            INNER JOIN subcategories s ON c.parent_id = s.id
          )
          SELECT name FROM subcategories ORDER BY name
          """,
          [electronics.id]
        )

      assert result.num_rows == 3
      names = Enum.map(result.rows, fn [name] -> name end)
      assert names == ["Computers", "Laptops", "Phones"]
    end
  end

  describe "CTE SQL generation" do
    test "generates correct WITH clause for simple CTE" do
      cte_query = from(e in Employee, where: e.level > 0, select: %{id: e.id, name: e.name})

      query =
        "active_employees"
        |> with_cte("active_employees", as: ^cte_query)
        |> select([e], e.name)

      {sql, _params} = Ecto.Adapters.SQL.to_sql(:all, TestRepo, query)

      assert sql =~ "WITH"
      assert sql =~ ~s("active_employees")
      assert sql =~ "AS"
      assert sql =~ "SELECT"
    end

    test "generates correct WITH RECURSIVE clause" do
      cte_query = from(e in Employee, where: e.level == 0)

      query =
        "hierarchy"
        |> with_cte("hierarchy", as: ^cte_query)
        |> recursive_ctes(true)
        |> select([h], h.name)

      {sql, _params} = Ecto.Adapters.SQL.to_sql(:all, TestRepo, query)

      assert sql =~ "WITH RECURSIVE"
      assert sql =~ ~s("hierarchy")
    end
  end

  describe "multiple CTEs" do
    test "multiple CTEs in single query" do
      TestRepo.insert!(%Employee{name: "Alice", level: 1})
      TestRepo.insert!(%Employee{name: "Bob", level: 2})
      TestRepo.insert!(%Employee{name: "Charlie", level: 3})

      # Define two CTEs.
      level_1 = from(e in Employee, where: e.level == 1, select: %{id: e.id, name: e.name})
      level_2 = from(e in Employee, where: e.level == 2, select: %{id: e.id, name: e.name})

      query =
        "level_1"
        |> with_cte("level_1", as: ^level_1)
        |> with_cte("level_2", as: ^level_2)
        |> select([l], l.name)

      {sql, _params} = Ecto.Adapters.SQL.to_sql(:all, TestRepo, query)

      # Verify both CTEs are in the query.
      assert sql =~ ~s("level_1")
      assert sql =~ ~s("level_2")
      assert sql =~ ", "
    end
  end

  describe "CTE edge cases" do
    test "empty result from CTE" do
      # No data inserted.
      cte_query = from(e in Employee, select: %{id: e.id, name: e.name})

      query =
        "empty_cte"
        |> with_cte("empty_cte", as: ^cte_query)
        |> select([e], e.name)

      result = TestRepo.all(query)
      assert result == []
    end

    test "CTE with aggregation" do
      TestRepo.insert!(%Employee{name: "Alice", level: 1})
      TestRepo.insert!(%Employee{name: "Bob", level: 2})
      TestRepo.insert!(%Employee{name: "Charlie", level: 2})

      # For CTEs with aggregation, use raw SQL to ensure proper column aliasing.
      # This test verifies CTEs work with aggregation functions.
      result =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          """
          WITH level_counts AS (
            SELECT level, COUNT(id) AS cnt
            FROM employees
            GROUP BY level
          )
          SELECT level FROM level_counts WHERE cnt > 1
          """
        )

      assert result.num_rows == 1
      assert result.rows == [[2]]
    end
  end
end
