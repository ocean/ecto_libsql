defmodule EctoLibSql.ReturningClauseTest do
  @moduledoc """
  Tests for RETURNING clause support in update_all and delete_all operations.

  These tests verify that queries with select clauses correctly generate
  RETURNING SQL and return the expected results instead of nil.

  This addresses the Protocol.UndefinedError that occurred when Ecto tried
  to enumerate nil values returned from bulk operations with select clauses.
  """

  use EctoLibSql.Integration.Case, async: false

  alias EctoLibSql.Integration.TestRepo
  alias EctoLibSql.Schemas.User

  import Ecto.Query

  @test_db "z_ecto_libsql_test-returning_clause.db"

  setup_all do
    # Clean up existing database files first.
    EctoLibSql.TestHelpers.cleanup_db_files(@test_db)

    # Configure the repo.
    Application.put_env(:ecto_libsql, EctoLibSql.Integration.TestRepo,
      adapter: Ecto.Adapters.LibSql,
      database: @test_db
    )

    {:ok, _} = EctoLibSql.Integration.TestRepo.start_link()

    # Run migrations.
    :ok =
      Ecto.Migrator.up(
        EctoLibSql.Integration.TestRepo,
        0,
        EctoLibSql.Integration.Migration,
        log: false
      )

    on_exit(fn ->
      EctoLibSql.TestHelpers.cleanup_db_files(@test_db)
    end)

    :ok
  end

  setup do
    # Clear users table before each test.
    Ecto.Adapters.SQL.query!(TestRepo, "DELETE FROM users", [])
    :ok
  end

  describe "update_all with RETURNING" do
    test "update_all without select returns {count, nil}" do
      # Without a select clause, rows should be nil.
      assert {0, nil} = TestRepo.update_all(User, set: [name: "Updated"])
    end

    test "update_all with select returns {count, []} when no rows match" do
      query = from(u in User, where: u.name == "NonExistent", select: %{name: u.name})

      # With select but no matching rows, should return empty list, not nil.
      assert {0, []} = TestRepo.update_all(query, set: [name: "Updated"])
    end

    test "update_all with select returns {count, [results]} when rows match" do
      {:ok, _} = TestRepo.insert(%User{name: "Alice"})
      {:ok, _} = TestRepo.insert(%User{name: "Bob"})

      query = from(u in User, where: u.name == "Alice", select: %{name: u.name})
      {count, results} = TestRepo.update_all(query, set: [name: "Updated"])

      assert count == 1
      assert is_list(results)
      assert length(results) == 1
      assert [%{name: "Updated"}] = results
    end

    test "update_all with select returns multiple results" do
      {:ok, _} = TestRepo.insert(%User{name: "User1"})
      {:ok, _} = TestRepo.insert(%User{name: "User2"})
      {:ok, _} = TestRepo.insert(%User{name: "User3"})

      query = from(u in User, select: %{name: u.name})
      {count, results} = TestRepo.update_all(query, set: [name: "AllUpdated"])

      assert count == 3
      assert is_list(results)
      assert length(results) == 3
      assert Enum.all?(results, fn r -> r.name == "AllUpdated" end)
    end

    test "update_all with select returning multiple fields" do
      {:ok, user} = TestRepo.insert(%User{name: "Alice"})

      query = from(u in User, where: u.id == ^user.id, select: %{id: u.id, name: u.name})
      {count, results} = TestRepo.update_all(query, set: [name: "Updated"])

      assert count == 1
      assert [%{id: id, name: "Updated"}] = results
      assert id == user.id
    end
  end

  describe "delete_all with RETURNING" do
    test "delete_all without select returns {count, nil}" do
      {:ok, _} = TestRepo.insert(%User{name: "Alice"})

      # Without a select clause, delete_all returns {count, nil}.
      assert {1, nil} = TestRepo.delete_all(User)
    end

    test "delete_all with select returns {count, []} when no rows match" do
      query = from(u in User, where: u.name == "NonExistent", select: u)

      # With select but no matching rows, should return empty list.
      assert {0, []} = TestRepo.delete_all(query)
    end

    test "delete_all with select returns {count, [results]} when rows match" do
      {:ok, _} = TestRepo.insert(%User{name: "ToDelete"})

      query = from(u in User, where: u.name == "ToDelete", select: %{name: u.name})
      {count, results} = TestRepo.delete_all(query)

      assert count == 1
      assert is_list(results)
      assert length(results) == 1
      assert [%{name: "ToDelete"}] = results
    end

    test "delete_all with select returns multiple deleted records" do
      {:ok, _} = TestRepo.insert(%User{name: "Delete1"})
      {:ok, _} = TestRepo.insert(%User{name: "Delete2"})

      query = from(u in User, select: %{name: u.name})
      {count, results} = TestRepo.delete_all(query)

      assert count == 2
      assert is_list(results)
      assert length(results) == 2
    end
  end

  describe "edge cases" do
    test "update_all with complex select expression" do
      {:ok, _} = TestRepo.insert(%User{name: "Test"})

      # Select with a constant value mixed with field.
      query = from(u in User, select: %{name: u.name, constant: 42})
      {count, results} = TestRepo.update_all(query, set: [name: "Updated"])

      assert count == 1
      assert [%{name: "Updated", constant: 42}] = results
    end

    test "update_all in transaction with select" do
      {:ok, _} = TestRepo.insert(%User{name: "TxTest"})

      result =
        TestRepo.transaction(fn ->
          query = from(u in User, where: u.name == "TxTest", select: %{name: u.name})
          TestRepo.update_all(query, set: [name: "TxUpdated"])
        end)

      assert {:ok, {1, [%{name: "TxUpdated"}]}} = result
    end

    test "delete_all in transaction with select" do
      {:ok, _} = TestRepo.insert(%User{name: "TxDelete"})

      result =
        TestRepo.transaction(fn ->
          query = from(u in User, where: u.name == "TxDelete", select: %{name: u.name})
          TestRepo.delete_all(query)
        end)

      assert {:ok, {1, [%{name: "TxDelete"}]}} = result
    end
  end
end
