defmodule EctoLibSql.ExplainSimpleTest do
  @moduledoc """
  Simpler test for EXPLAIN query support to debug the issue.
  """

  use ExUnit.Case, async: false

  defmodule TestRepo do
    use Ecto.Repo,
      otp_app: :ecto_libsql,
      adapter: Ecto.Adapters.LibSql
  end

  @test_db "z_ecto_libsql_test-explain-simple.db"

  setup_all do
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

      GenServer.stop(TestRepo)
    end)

    {:ok, []}
  end

  test "direct EXPLAIN query via SQL" do
    # Test that executing EXPLAIN directly works
    sql = "EXPLAIN QUERY PLAN SELECT * FROM explain_test_users"
    {:ok, result} = Ecto.Adapters.SQL.query(TestRepo, sql, [])

    assert is_struct(result, EctoLibSql.Result)
    assert is_list(result.rows)
    # EXPLAIN QUERY PLAN returns rows with columns: addr, opcode, p1, p2, p3, p4, p5, comment
    assert length(result.columns) >= 8
  end

  test "EXPLAIN via explain API returns rows" do
    # Import Ecto.Query
    import Ecto.Query

    defmodule User do
      use Ecto.Schema

      schema "explain_test_users" do
        field(:name, :string)
        field(:email, :string)
      end
    end

    # Build a simple query
    query = from(u in User, select: u.name)

    # The result should be a list of maps
    result = Ecto.Adapters.SQL.explain(TestRepo, :all, query)

    # Check it's a list of results
    assert is_list(result)
    IO.inspect(result, label: "EXPLAIN result")
  end
end
