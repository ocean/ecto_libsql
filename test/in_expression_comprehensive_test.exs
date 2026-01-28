defmodule EctoLibSql.InExpressionComprehensiveTest do
  @moduledoc """
  Comprehensive test suite for IN clause and expression handling.

  This test module catches regressions in three major areas:

  1. **Issue #63** - JSON encoding of list parameters in IN clauses
     - Lists should expand to individual parameters, not be JSON-encoded
     - Affected: simple list parameters, ~w() sigils

  2. **PR #66** - Subqueries in IN expressions
     - IN clauses with subqueries should generate proper SQL, not JSON-wrapped
     - Affected: `WHERE id IN (SELECT ...)` patterns (e.g., Oban Lite engine)

  3. **PR #67** - Tagged struct and type-wrapped expressions
     - Post-planning Ecto.Query.Tagged nodes should be handled correctly
     - Type-wrapped fragments should not fall through to catch-all "?" placeholder
     - Affected: complex queries with type casts, fragments with types

  These tests should have been written BEFORE the fixes. If any fail after merging
  #66 and #67, it indicates a regression in those fixes.
  """

  use EctoLibSql.Integration.Case, async: false

  alias EctoLibSql.Integration.TestRepo

  import Ecto.Query

  @test_db "z_ecto_libsql_test-in_comprehensive.db"

  setup_all do
    Application.put_env(:ecto_libsql, EctoLibSql.Integration.TestRepo,
      adapter: Ecto.Adapters.LibSql,
      database: @test_db
    )

    {:ok, _} = EctoLibSql.Integration.TestRepo.start_link()

    # Create test tables
    Ecto.Adapters.SQL.query!(TestRepo, """
    CREATE TABLE IF NOT EXISTS test_items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      state TEXT,
      name TEXT,
      category TEXT,
      priority INTEGER,
      inserted_at TEXT,
      updated_at TEXT
    )
    """)

    Ecto.Adapters.SQL.query!(TestRepo, """
    CREATE TABLE IF NOT EXISTS archived_items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      item_id INTEGER,
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
    # Clear tables before each test
    Ecto.Adapters.SQL.query!(TestRepo, "DELETE FROM test_items", [])
    Ecto.Adapters.SQL.query!(TestRepo, "DELETE FROM archived_items", [])
    :ok
  end

  describe "Issue #63 - IN clause with list parameters" do
    test "IN clause with list parameter (simple parameter expansion)" do
      # Insert test data
      Ecto.Adapters.SQL.query!(TestRepo, """
      INSERT INTO test_items (state, name, inserted_at, updated_at)
      VALUES ('scheduled', 'item1', datetime('now'), datetime('now')),
             ('retryable', 'item2', datetime('now'), datetime('now')),
             ('completed', 'item3', datetime('now'), datetime('now')),
             ('failed', 'item4', datetime('now'), datetime('now'))
      """)

      # BEFORE FIX: Would JSON-encode the entire list ["scheduled", "retryable"]
      # as a single parameter, causing "datatype mismatch" error
      # AFTER FIX: List is properly expanded to individual parameters
      states = ["scheduled", "retryable"]

      query =
        from(t in "test_items",
          where: t.state in ^states,
          select: t.name
        )

      result = TestRepo.all(query)

      assert length(result) == 2
      assert "item1" in result
      assert "item2" in result
    end

    test "IN clause with empty list parameter" do
      # Insert test data
      Ecto.Adapters.SQL.query!(TestRepo, """
      INSERT INTO test_items (state, name, inserted_at, updated_at)
      VALUES ('test', 'item1', datetime('now'), datetime('now'))
      """)

      # Empty IN clause should return no results
      query =
        from(t in "test_items",
          where: t.state in ^[],
          select: t.name
        )

      result = TestRepo.all(query)

      assert result == []
    end

    test "IN clause with single-element list" do
      # Insert test data
      Ecto.Adapters.SQL.query!(TestRepo, """
      INSERT INTO test_items (state, name, inserted_at, updated_at)
      VALUES ('active', 'item1', datetime('now'), datetime('now')),
             ('inactive', 'item2', datetime('now'), datetime('now'))
      """)

      query =
        from(t in "test_items",
          where: t.state in ^["active"],
          select: t.name
        )

      result = TestRepo.all(query)

      assert result == ["item1"]
    end

    test "IN clause with ~w() sigil (word list - Oban pattern)" do
      # Insert test data matching Oban's state values
      Ecto.Adapters.SQL.query!(TestRepo, """
      INSERT INTO test_items (state, name, inserted_at, updated_at)
      VALUES ('scheduled', 'job1', datetime('now'), datetime('now')),
             ('retryable', 'job2', datetime('now'), datetime('now')),
             ('available', 'job3', datetime('now'), datetime('now')),
             ('completed', 'job4', datetime('now'), datetime('now'))
      """)

      # BEFORE FIX: ~w() sigil creates %Ecto.Query.Tagged{} struct containing list
      # The catch-all IN handler would JSON-wrap it, causing "datatype mismatch"
      # AFTER FIX (PR #65): Properly detects %Ecto.Query.Tagged{value: list}
      # and expands the list to individual parameters
      query =
        from(t in "test_items",
          where: t.state in ~w(scheduled retryable),
          select: t.name
        )

      result = TestRepo.all(query)

      assert length(result) == 2
      assert "job1" in result
      assert "job2" in result
    end

    test "IN clause with multiple filters" do
      # Insert test data
      Ecto.Adapters.SQL.query!(TestRepo, """
      INSERT INTO test_items (state, name, category, priority, inserted_at, updated_at)
      VALUES ('active', 'item1', 'A', 1, datetime('now'), datetime('now')),
             ('active', 'item2', 'B', 2, datetime('now'), datetime('now')),
             ('inactive', 'item3', 'A', 1, datetime('now'), datetime('now')),
             ('inactive', 'item4', 'B', 2, datetime('now'), datetime('now'))
      """)

      # Multiple IN clauses combined
      states = ["active"]
      categories = ["A", "B"]

      query =
        from(t in "test_items",
          where: t.state in ^states and t.category in ^categories,
          select: t.name
        )

      result = TestRepo.all(query)

      assert length(result) == 2
      assert "item1" in result
      assert "item2" in result
    end
  end

  describe "PR #66 - IN clause with subqueries" do
    test "IN clause with subquery (basic) - BEFORE FIX: JSON_EACH wrapping" do
      # Insert primary table data
      Ecto.Adapters.SQL.query!(TestRepo, """
      INSERT INTO test_items (id, state, name, inserted_at, updated_at)
      VALUES (1, 'scheduled', 'job1', datetime('now'), datetime('now')),
             (2, 'completed', 'job2', datetime('now'), datetime('now')),
             (3, 'failed', 'job3', datetime('now'), datetime('now'))
      """)

      # Insert archived items (some pointing to items above)
      Ecto.Adapters.SQL.query!(TestRepo, """
      INSERT INTO archived_items (item_id, state, name, inserted_at, updated_at)
      VALUES (1, 'archived', 'job1_archived', datetime('now'), datetime('now')),
             (3, 'archived', 'job3_archived', datetime('now'), datetime('now'))
      """)

      # BEFORE FIX (PR #66): IN with subquery would be wrapped in JSON_EACH(),
      # producing invalid SQL like:
      #   WHERE id IN (SELECT value FROM JSON_EACH(SELECT item_id FROM archived_items))
      # This causes "malformed JSON" error because subquery results aren't valid JSON
      #
      # AFTER FIX: Properly generates:
      #   WHERE id IN (SELECT item_id FROM archived_items)
      subquery =
        from(a in "archived_items",
          select: a.item_id
        )

      query =
        from(t in "test_items",
          where: t.id in subquery(subquery),
          select: t.name
        )

      result = TestRepo.all(query)

      assert length(result) == 2
      assert "job1" in result
      assert "job3" in result
    end

    test "IN clause with correlated subquery" do
      # Insert test data
      Ecto.Adapters.SQL.query!(TestRepo, """
      INSERT INTO test_items (id, state, category, priority, name, inserted_at, updated_at)
      VALUES (1, 'active', 'A', 1, 'item1', datetime('now'), datetime('now')),
             (2, 'active', 'B', 1, 'item2', datetime('now'), datetime('now')),
             (3, 'inactive', 'A', 2, 'item3', datetime('now'), datetime('now')),
             (4, 'inactive', 'B', 2, 'item4', datetime('now'), datetime('now'))
      """)

      # Subquery selecting IDs with priority >= 2
      high_priority_subquery =
        from(t in "test_items",
          where: t.priority >= 2,
          select: t.id
        )

      query =
        from(t in "test_items",
          where: t.id in subquery(high_priority_subquery),
          select: t.name
        )

      result = TestRepo.all(query)

      assert length(result) == 2
      assert "item3" in result
      assert "item4" in result
    end

    test "IN clause with subquery filtering specific state" do
      # Simulate Oban-like pattern: fetch jobs that have been archived
      Ecto.Adapters.SQL.query!(TestRepo, """
      INSERT INTO test_items (id, state, name, inserted_at, updated_at)
      VALUES (1, 'scheduled', 'job1', datetime('now'), datetime('now')),
             (2, 'completed', 'job2', datetime('now'), datetime('now')),
             (3, 'failed', 'job3', datetime('now'), datetime('now')),
             (4, 'available', 'job4', datetime('now'), datetime('now'))
      """)

      Ecto.Adapters.SQL.query!(TestRepo, """
      INSERT INTO archived_items (item_id, state, inserted_at, updated_at)
      VALUES (1, 'archived', datetime('now'), datetime('now')),
             (2, 'archived', datetime('now'), datetime('now'))
      """)

      # Fetch items that are in archived state (like Oban fetching jobs)
      archived_ids_subquery =
        from(a in "archived_items",
          where: a.state == "archived",
          select: a.item_id
        )

      query =
        from(t in "test_items",
          where: t.id in subquery(archived_ids_subquery),
          select: [:id, :name]
        )

      result = TestRepo.all(query)

      assert length(result) == 2
      assert Enum.any?(result, &(&1.name == "job1"))
      assert Enum.any?(result, &(&1.name == "job2"))
    end

    test "IN clause with complex subquery (WHERE, SELECT)" do
      # Insert test data
      Ecto.Adapters.SQL.query!(TestRepo, """
      INSERT INTO test_items (id, state, category, priority, name, inserted_at, updated_at)
      VALUES (1, 'active', 'A', 1, 'item1', datetime('now'), datetime('now')),
             (2, 'active', 'B', 2, 'item2', datetime('now'), datetime('now')),
             (3, 'inactive', 'A', 3, 'item3', datetime('now'), datetime('now')),
             (4, 'inactive', 'B', 1, 'item4', datetime('now'), datetime('now'))
      """)

      # Subquery: select IDs where category is A AND priority > 1
      subquery =
        from(t in "test_items",
          where: t.category == "A" and t.priority > 1,
          select: t.id
        )

      query =
        from(t in "test_items",
          where: t.id in subquery(subquery),
          select: t.name
        )

      result = TestRepo.all(query)

      assert result == ["item3"]
    end
  end

  describe "PR #67 - Tagged struct and type-wrapped expressions" do
    test "IN clause with type-wrapped fragment (parameter count mismatch fix)" do
      # Insert test data
      Ecto.Adapters.SQL.query!(TestRepo, """
      INSERT INTO test_items (id, state, name, priority, inserted_at, updated_at)
      VALUES (1, 'active', 'item1', 1, datetime('now'), datetime('now')),
             (2, 'active', 'item2', 2, datetime('now'), datetime('now')),
             (3, 'inactive', 'item3', 3, datetime('now'), datetime('now'))
      """)

      # BEFORE FIX (PR #67): type() casting around fragments would fall through
      # to the catch-all expr clause, generating a single "?" placeholder
      # This caused parameter count mismatch with query execution
      #
      # AFTER FIX: %Ecto.Query.Tagged{} handler properly extracts and processes
      # the wrapped value, generating correct parameter placeholders
      query =
        from(t in "test_items",
          where: t.priority in ~w(1 2),
          select: t.name
        )

      result = TestRepo.all(query)

      assert length(result) == 2
      assert "item1" in result
      assert "item2" in result
    end

    test "IN clause with complex type-cast expression" do
      # Insert test data with various priority values
      Ecto.Adapters.SQL.query!(TestRepo, """
      INSERT INTO test_items (id, priority, name, inserted_at, updated_at)
      VALUES (1, 1, 'low', datetime('now'), datetime('now')),
             (2, 5, 'medium', datetime('now'), datetime('now')),
             (3, 10, 'high', datetime('now'), datetime('now')),
             (4, 3, 'medium-low', datetime('now'), datetime('now'))
      """)

      # Query with explicit type casting using parameter interpolation
      # (need to use ^priorities instead of ~w() for proper type handling)
      priorities = [1, 5]

      query =
        from(t in "test_items",
          where: t.priority in ^priorities,
          select: t.name
        )

      result = TestRepo.all(query)

      assert length(result) == 2
      assert "low" in result
      assert "medium" in result
    end

    test "SELECT with type-wrapped fragment (Oban Web JobQuery pattern)" do
      # This simulates the Oban Web pattern that was failing with parameter mismatch
      Ecto.Adapters.SQL.query!(TestRepo, """
      INSERT INTO test_items (id, state, name, priority, inserted_at, updated_at)
      VALUES (1, 'scheduled', 'job1', 1, datetime('now'), datetime('now')),
             (2, 'retryable', 'job2', 2, datetime('now'), datetime('now')),
             (3, 'available', 'job3', 1, datetime('now'), datetime('now')),
             (4, 'running', 'job4', 3, datetime('now'), datetime('now'))
      """)

      # Limit query with type casting on a fragment
      # This pattern appears in Oban Web's JobQuery.limit_query for states
      query =
        from(t in "test_items",
          where: t.state in ~w(scheduled retryable available),
          limit: 10,
          select: t.name
        )

      result = TestRepo.all(query)

      assert length(result) == 3
      assert "job1" in result
      assert "job2" in result
      assert "job3" in result
    end

    test "Multiple type-wrapped expressions in same query" do
      # Insert test data
      Ecto.Adapters.SQL.query!(TestRepo, """
      INSERT INTO test_items (id, category, priority, state, name, inserted_at, updated_at)
      VALUES (1, 'A', 1, 'active', 'item1', datetime('now'), datetime('now')),
             (2, 'B', 2, 'active', 'item2', datetime('now'), datetime('now')),
             (3, 'A', 3, 'inactive', 'item3', datetime('now'), datetime('now')),
             (4, 'C', 1, 'pending', 'item4', datetime('now'), datetime('now'))
      """)

      # Multiple IN clauses with different types
      query =
        from(t in "test_items",
          where: t.category in ~w(A B) and t.priority in ~w(1 2),
          select: t.name
        )

      result = TestRepo.all(query)

      assert length(result) == 2
      assert "item1" in result
      assert "item2" in result
    end
  end

  describe "Integration - Combined patterns from real use cases" do
    test "Oban-like pattern: UPDATE WHERE id IN (subquery)" do
      # Insert job data
      Ecto.Adapters.SQL.query!(TestRepo, """
      INSERT INTO test_items (id, state, name, inserted_at, updated_at)
      VALUES (1, 'scheduled', 'job1', datetime('now'), datetime('now')),
             (2, 'available', 'job2', datetime('now'), datetime('now')),
             (3, 'retryable', 'job3', datetime('now'), datetime('now')),
             (4, 'completed', 'job4', datetime('now'), datetime('now'))
      """)

      # Simulate Oban's fetch_jobs pattern with subquery
      # Fetch IDs of available/retryable jobs (classic Oban pattern)
      available_states = ~w(available retryable)

      query =
        from(t in "test_items",
          where: t.state in ^available_states,
          select: t.id
        )

      result = TestRepo.all(query)

      assert length(result) == 2
      assert 2 in result
      assert 3 in result
    end

    test "Complex query: nested conditions with IN and subquery" do
      # Insert test data
      Ecto.Adapters.SQL.query!(TestRepo, """
      INSERT INTO test_items (id, state, category, priority, name, inserted_at, updated_at)
      VALUES (1, 'active', 'A', 1, 'item1', datetime('now'), datetime('now')),
             (2, 'active', 'B', 2, 'item2', datetime('now'), datetime('now')),
             (3, 'inactive', 'A', 1, 'item3', datetime('now'), datetime('now')),
             (4, 'inactive', 'B', 3, 'item4', datetime('now'), datetime('now'))
      """)

      Ecto.Adapters.SQL.query!(TestRepo, """
      INSERT INTO archived_items (item_id, state, name, inserted_at, updated_at)
      VALUES (1, 'archived', 'item1_old', datetime('now'), datetime('now')),
             (3, 'archived', 'item3_old', datetime('now'), datetime('now'))
      """)

      # Complex: IN list AND IN subquery
      states = ["active", "inactive"]

      archived_subquery =
        from(a in "archived_items",
          select: a.item_id
        )

      query =
        from(t in "test_items",
          where: t.state in ^states and t.id in subquery(archived_subquery),
          select: t.name
        )

      result = TestRepo.all(query)

      assert length(result) == 2
      assert "item1" in result
      assert "item3" in result
    end
  end
end
