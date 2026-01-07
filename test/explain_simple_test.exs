defmodule EctoLibSql.ExplainSimpleTest do
  @moduledoc """
  Simpler test for EXPLAIN query support to debug the issue.
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

    schema "explain_test_users" do
      field(:name, :string)
      field(:email, :string)
    end
  end

  @test_db "z_ecto_libsql_test-explain-simple.db"

  setup_all do
    # Clean up any existing test database files
    File.rm(@test_db)
    File.rm(@test_db <> "-shm")
    File.rm(@test_db <> "-wal")

    {:ok, _} = TestRepo.start_link(database: @test_db)

    Ecto.Adapters.SQL.query!(TestRepo, """
    CREATE TABLE IF NOT EXISTS explain_test_users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      email TEXT NOT NULL
    )
    """)

    on_exit(fn ->
      try do
        Ecto.Adapters.SQL.query!(TestRepo, "DROP TABLE IF EXISTS explain_test_users")
      catch
        _, _ -> nil
      end

      try do
        GenServer.stop(TestRepo)
      catch
        _, _ -> nil
      end

      # Clean up all database files
      File.rm(@test_db)
      File.rm(@test_db <> "-shm")
      File.rm(@test_db <> "-wal")
    end)

    {:ok, []}
  end

  test "direct EXPLAIN query via SQL" do
    # Test that executing EXPLAIN directly works
    sql = "EXPLAIN QUERY PLAN SELECT * FROM explain_test_users"
    {:ok, result} = Ecto.Adapters.SQL.query(TestRepo, sql, [])

    assert is_struct(result, EctoLibSql.Result)
    assert is_list(result.rows)
    # EXPLAIN QUERY PLAN returns rows with columns: id, parent, notused, detail
    assert length(result.columns) == 4
    assert result.columns == ["id", "parent", "notused", "detail"]
    assert length(result.rows) > 0
  end

  test "EXPLAIN via explain API returns rows" do
    # Build a simple query.
    query = from(u in User, select: u.name)

    # The result should be a list of maps.
    result = Ecto.Adapters.SQL.explain(TestRepo, :all, query)

    # Check it's a list of results.
    assert is_list(result)
    assert length(result) > 0
  end

  test "EXPLAIN on non-existent table returns error" do
    sql = "EXPLAIN QUERY PLAN SELECT * FROM non_existent_table"

    assert {:error, %EctoLibSql.Error{message: message}} =
             Ecto.Adapters.SQL.query(TestRepo, sql, [])

    assert message =~ "no such table" or message =~ "non_existent_table"
  end

  test "EXPLAIN with invalid SQL syntax returns error" do
    sql = "EXPLAIN QUERY PLAN SELECTT * FROM explain_test_users"

    assert {:error, %EctoLibSql.Error{}} = Ecto.Adapters.SQL.query(TestRepo, sql, [])
  end

  test "EXPLAIN on empty table returns query plan" do
    # EXPLAIN should work even on empty tables - it shows the query plan, not data.
    sql = "EXPLAIN QUERY PLAN SELECT * FROM explain_test_users WHERE id = 999999"
    {:ok, result} = Ecto.Adapters.SQL.query(TestRepo, sql, [])

    assert is_struct(result, EctoLibSql.Result)
    assert is_list(result.rows)
    # Should still return a query plan even for a query that would return no rows.
    assert length(result.rows) > 0
  end
end
