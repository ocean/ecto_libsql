defmodule EctoLibSql.Issue63InClauseTest do
  @moduledoc """
  Test case for issue #63: Datatype mismatch due to JSON encoding of lists in IN statements.

  The issue occurs when lists are used as parameters in IN clauses.
  Instead of expanding the list into individual parameters, the entire list
  was being JSON-encoded as a single string parameter, causing SQLite to raise
  a "datatype mismatch" error.
  """

  use EctoLibSql.Integration.Case, async: false

  alias EctoLibSql.Integration.TestRepo
  alias EctoLibSql.Schemas.Product

  import Ecto.Query

  @test_db "z_ecto_libsql_test-issue_63.db"

  setup_all do
    Application.put_env(:ecto_libsql, EctoLibSql.Integration.TestRepo,
      adapter: Ecto.Adapters.LibSql,
      database: @test_db
    )

    {:ok, _} = EctoLibSql.Integration.TestRepo.start_link()

    # Create test table with state column
    Ecto.Adapters.SQL.query!(TestRepo, """
    CREATE TABLE IF NOT EXISTS test_items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      state TEXT,
      name TEXT,
      inserted_at TEXT,
      updated_at TEXT
    )
    """)

    on_exit(fn ->
      EctoLibSql.TestHelpers.cleanup_db_files(@test_db)
    end)

    :ok
  end

  setup do
    # Clear table before each test
    Ecto.Adapters.SQL.query!(TestRepo, "DELETE FROM test_items", [])
    :ok
  end

  test "IN clause with list parameter should not JSON-encode the list" do
    # Insert test data with various states
    Ecto.Adapters.SQL.query!(TestRepo, """
    INSERT INTO test_items (state, name, inserted_at, updated_at)
    VALUES ('scheduled', 'item1', datetime('now'), datetime('now')),
           ('retryable', 'item2', datetime('now'), datetime('now')),
           ('completed', 'item3', datetime('now'), datetime('now')),
           ('failed', 'item4', datetime('now'), datetime('now'))
    """)

    # This query should work without datatype mismatch error
    # Using a list parameter in an IN clause
    states = ["scheduled", "retryable"]

    query =
      from(t in "test_items",
        where: t.state in ^states,
        select: t.name
      )

    # Execute the query - this should not raise "datatype mismatch" error
    result = TestRepo.all(query)

    # Should return the two items with scheduled or retryable state
    assert length(result) == 2
    assert "item1" in result
    assert "item2" in result
  end

  test "IN clause with multiple parameter lists should work correctly" do
    # Insert test data
    Ecto.Adapters.SQL.query!(TestRepo, """
    INSERT INTO test_items (state, name, inserted_at, updated_at)
    VALUES ('active', 'item1', datetime('now'), datetime('now')),
           ('inactive', 'item2', datetime('now'), datetime('now')),
           ('pending', 'item3', datetime('now'), datetime('now'))
    """)

    # Query with multiple filters including IN clause
    states = ["active", "pending"]

    query =
      from(t in "test_items",
        where: t.state in ^states,
        select: t.name
      )

    result = TestRepo.all(query)

    assert length(result) == 2
    assert "item1" in result
    assert "item3" in result
  end

  test "IN clause with empty list parameter" do
    # Insert test data
    Ecto.Adapters.SQL.query!(TestRepo, """
    INSERT INTO test_items (state, name, inserted_at, updated_at)
    VALUES ('test', 'item1', datetime('now'), datetime('now'))
    """)

    # Query with empty list should return no results
    query =
      from(t in "test_items",
        where: t.state in ^[],
        select: t.name
      )

    result = TestRepo.all(query)

    # Empty IN clause should match nothing
    assert result == []
  end
end
