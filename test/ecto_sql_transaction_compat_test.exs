defmodule EctoLibSql.EctoSqlTransactionCompatTest do
  @moduledoc """
  Tests ported from ecto_sql to verify transaction compatibility.
  Source: ecto_sql/integration_test/sql/transaction.exs

  These tests verify that EctoLibSql correctly handles:
  - Transaction commits and rollbacks
  - Nested transactions (via SAVEPOINT in SQLite)
  - Manual rollback operations
  - Transaction isolation
  - LibSQL-specific transaction modes (DEFERRED, IMMEDIATE, EXCLUSIVE, READ_ONLY)

  Note: Each test gets its own database file and repo instance to avoid SQLite
  locking issues. Tests run serially (async: false) since they all use the same
  TestRepo name.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  # Define test repo module (will be started per-test with unique database)
  defmodule TestRepo do
    use Ecto.Repo,
      otp_app: :ecto_libsql,
      adapter: Ecto.Adapters.LibSql
  end

  defmodule Trans do
    use Ecto.Schema

    schema "transactions" do
      field(:num, :integer)
    end
  end

  defmodule UniqueError do
    defexception message: "unique error"
  end

  # Time to allow for SQLite file handles to be released after repo shutdown
  @cleanup_delay_ms 50

  setup do
    # Create a unique database file for THIS test
    unique_id = :erlang.unique_integer([:positive])
    test_db = "z_ecto_libsql_test-transaction_compat-#{unique_id}.db"

    # Start a repo specifically for this test
    # Always use TestRepo as the name so tests don't need to change
    {:ok, pid} =
      TestRepo.start_link(
        database: test_db,
        pool_size: 1,
        name: TestRepo
      )

    # Enable WAL mode for better concurrency
    Ecto.Adapters.SQL.query(TestRepo, "PRAGMA journal_mode=WAL")
    # Set busy timeout
    Ecto.Adapters.SQL.query(TestRepo, "PRAGMA busy_timeout=10000")

    # Create transactions table
    Ecto.Adapters.SQL.query!(TestRepo, """
    CREATE TABLE IF NOT EXISTS transactions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      num INTEGER
    )
    """)

    on_exit(fn ->
      # Stop this test's repo
      if Process.alive?(pid) do
        try do
          :ok = Supervisor.stop(pid)
        catch
          # Handle cases where supervisor is already stopping or stopped
          :exit, {:noproc, _} ->
            :ok

          # Normal shutdown patterns from GenServer.stop
          :exit, {:shutdown, _} ->
            :ok

          :exit, {{:shutdown, _}, _} ->
            :ok

          # Unexpected exits - log for debugging
          :exit, reason ->
            IO.warn("Unexpected exit during test cleanup: #{inspect(reason)}")
            :ok
        end
      end

      # Wait a bit for cleanup
      Process.sleep(@cleanup_delay_ms)

      # Clean up all database files (ignore errors if files don't exist)
      EctoLibSql.TestHelpers.cleanup_db_files(test_db)
    end)

    :ok
  end

  describe "basic transaction behaviour" do
    test "transaction returns value" do
      refute TestRepo.in_transaction?()

      {:ok, val} =
        TestRepo.transaction(fn ->
          assert TestRepo.in_transaction?()

          {:ok, val} =
            TestRepo.transaction(fn ->
              assert TestRepo.in_transaction?()
              42
            end)

          assert TestRepo.in_transaction?()
          val
        end)

      refute TestRepo.in_transaction?()
      assert val == 42
    end

    test "transaction re-raises errors" do
      assert_raise UniqueError, fn ->
        TestRepo.transaction(fn ->
          TestRepo.transaction(fn ->
            raise UniqueError
          end)
        end)
      end
    end

    test "transaction commits successfully" do
      TestRepo.transaction(fn ->
        e = TestRepo.insert!(%Trans{num: 1})
        assert [^e] = TestRepo.all(Trans)
      end)

      assert [%Trans{num: 1}] = TestRepo.all(Trans)
    end

    test "transaction rolls back on error" do
      try do
        TestRepo.transaction(fn ->
          e = TestRepo.insert!(%Trans{num: 2})
          assert [^e] = TestRepo.all(Trans)
          raise UniqueError
        end)
      rescue
        UniqueError -> :ok
      end

      assert [] = TestRepo.all(Trans)
    end
  end

  describe "nested transactions (savepoints)" do
    test "nested transaction partial rollback" do
      assert TestRepo.transaction(fn ->
               e1 = TestRepo.insert!(%Trans{num: 3})
               assert [^e1] = TestRepo.all(Trans)

               try do
                 TestRepo.transaction(fn ->
                   e2 = TestRepo.insert!(%Trans{num: 4})
                   assert [^e1, ^e2] = TestRepo.all(from(t in Trans, order_by: t.num))
                   raise UniqueError
                 end)
               rescue
                 UniqueError -> :ok
               end

               # After nested rollback, outer transaction is poisoned in SQLite
               # This behaviour differs from PostgreSQL
               assert_raise DBConnection.ConnectionError, ~r/transaction rolling back/, fn ->
                 TestRepo.insert!(%Trans{num: 5})
               end
             end) == {:error, :rollback}

      assert TestRepo.all(Trans) == []
    end

    test "manual rollback doesn't bubble up" do
      x =
        TestRepo.transaction(fn ->
          e = TestRepo.insert!(%Trans{num: 6})
          assert [^e] = TestRepo.all(Trans)
          TestRepo.rollback(:oops)
        end)

      assert x == {:error, :oops}
      assert [] = TestRepo.all(Trans)
    end

    test "manual rollback bubbles up on nested transaction" do
      assert TestRepo.transaction(fn ->
               e = TestRepo.insert!(%Trans{num: 7})
               assert [^e] = TestRepo.all(Trans)

               assert {:error, :oops} =
                        TestRepo.transaction(fn ->
                          TestRepo.rollback(:oops)
                        end)

               assert_raise DBConnection.ConnectionError, ~r/transaction rolling back/, fn ->
                 TestRepo.insert!(%Trans{num: 8})
               end
             end) == {:error, :rollback}

      assert [] = TestRepo.all(Trans)
    end
  end

  describe "transaction isolation" do
    # SQLite uses file-level locking, not PostgreSQL-style row-level locking
    @tag :sqlite_limitation
    test "rollback is per repository connection" do
      message = "cannot call rollback outside of transaction"

      assert_raise RuntimeError, message, fn ->
        TestRepo.rollback(:done)
      end
    end

    # SQLite uses file-level locking, not PostgreSQL-style row-level locking
    @tag :sqlite_limitation
    test "transactions are not shared across processes" do
      pid = self()

      new_pid =
        spawn_link(fn ->
          TestRepo.transaction(fn ->
            e = TestRepo.insert!(%Trans{num: 9})
            assert [^e] = TestRepo.all(Trans)
            send(pid, :in_transaction)

            receive do
              :commit -> :ok
            after
              5000 -> raise "timeout"
            end
          end)

          send(pid, :committed)
        end)

      receive do
        :in_transaction -> :ok
      after
        5000 -> raise "timeout"
      end

      # Other process is in transaction, but we shouldn't see the data yet
      TestRepo.transaction(fn ->
        assert [] = TestRepo.all(Trans)
      end)

      send(new_pid, :commit)

      receive do
        :committed -> :ok
      after
        5000 -> raise "timeout"
      end

      # Now we should see the committed data
      assert [%Trans{num: 9}] = TestRepo.all(Trans)
    end
  end

  describe "LibSQL transaction modes" do
    test "DEFERRED transaction mode (default)" do
      # DEFERRED: lock is acquired on first write
      {:ok, result} =
        TestRepo.transaction(
          fn ->
            # Read doesn't acquire lock
            assert [] = TestRepo.all(Trans)

            # Write acquires lock
            TestRepo.insert!(%Trans{num: 10})
            :ok
          end,
          mode: :deferred
        )

      assert result == :ok
      assert [%Trans{num: 10}] = TestRepo.all(Trans)
    end

    test "IMMEDIATE transaction mode" do
      # IMMEDIATE: reserved lock acquired immediately
      {:ok, result} =
        TestRepo.transaction(
          fn ->
            # Lock is already acquired
            TestRepo.insert!(%Trans{num: 11})
            :ok
          end,
          mode: :immediate
        )

      assert result == :ok
      assert [%Trans{num: 11}] = TestRepo.all(Trans)
    end

    test "EXCLUSIVE transaction mode" do
      # EXCLUSIVE: exclusive lock, blocks all other connections
      {:ok, result} =
        TestRepo.transaction(
          fn ->
            TestRepo.insert!(%Trans{num: 12})
            :ok
          end,
          mode: :exclusive
        )

      assert result == :ok
      assert [%Trans{num: 12}] = TestRepo.all(Trans)
    end

    test "READ_ONLY transaction mode" do
      # Insert data first
      TestRepo.insert!(%Trans{num: 13})

      # READ_ONLY: no locks, read-only access
      {:ok, result} =
        TestRepo.transaction(
          fn ->
            assert [%Trans{num: 13}] = TestRepo.all(Trans)
            :ok
          end,
          mode: :read_only
        )

      assert result == :ok
    end

    test "transaction mode rollback works correctly" do
      result =
        TestRepo.transaction(
          fn ->
            TestRepo.insert!(%Trans{num: 14})
            TestRepo.rollback(:abort)
          end,
          mode: :immediate
        )

      assert result == {:error, :abort}
      assert [] = TestRepo.all(Trans)
    end
  end

  describe "checkout operations" do
    test "transaction inside checkout" do
      TestRepo.checkout(fn ->
        refute TestRepo.in_transaction?()

        TestRepo.transaction(fn ->
          assert TestRepo.in_transaction?()
        end)

        refute TestRepo.in_transaction?()
      end)
    end

    test "checkout inside transaction" do
      TestRepo.transaction(fn ->
        assert TestRepo.in_transaction?()

        TestRepo.checkout(fn ->
          assert TestRepo.in_transaction?()
        end)

        assert TestRepo.in_transaction?()
      end)
    end
  end

  describe "error handling" do
    test "transaction is not left open on query error" do
      refute TestRepo.in_transaction?()

      # EctoLibSql raises EctoLibSql.Error instead of Ecto.QueryError
      assert_raise EctoLibSql.Error, fn ->
        TestRepo.transaction(fn ->
          # This should fail - invalid SQL
          Ecto.Adapters.SQL.query!(TestRepo, "INVALID SQL QUERY")
        end)
      end

      # Transaction should not be left open
      refute TestRepo.in_transaction?()
    end

    test "transaction state is clean after rollback" do
      {:error, :manual_rollback} =
        TestRepo.transaction(fn ->
          TestRepo.insert!(%Trans{num: 15})
          TestRepo.rollback(:manual_rollback)
        end)

      # Should be able to start a new transaction
      {:ok, :success} =
        TestRepo.transaction(fn ->
          TestRepo.insert!(%Trans{num: 16})
          :success
        end)

      assert [%Trans{num: 16}] = TestRepo.all(Trans)
    end
  end

  describe "complex transaction scenarios" do
    test "multiple operations in single transaction" do
      {:ok, count} =
        TestRepo.transaction(fn ->
          TestRepo.insert!(%Trans{num: 20})
          TestRepo.insert!(%Trans{num: 21})
          TestRepo.insert!(%Trans{num: 22})

          # Update all
          TestRepo.update_all(Trans, set: [num: 99])

          # Count
          TestRepo.all(Trans) |> length()
        end)

      assert count == 3
      assert Enum.all?(TestRepo.all(Trans), fn t -> t.num == 99 end)
    end

    test "transaction with query, insert, update, and delete" do
      # Pre-insert some data
      TestRepo.insert!(%Trans{num: 100})
      TestRepo.insert!(%Trans{num: 101})

      {:ok, result} =
        TestRepo.transaction(fn ->
          # Query
          existing = TestRepo.all(Trans)
          assert length(existing) == 2

          # Insert
          new = TestRepo.insert!(%Trans{num: 102})

          # Update
          TestRepo.update!(Ecto.Changeset.change(new, num: 103))

          # Delete one
          first = hd(existing)
          TestRepo.delete!(first)

          # Return final count
          TestRepo.all(Trans) |> length()
        end)

      assert result == 2
      nums = TestRepo.all(Trans) |> Enum.map(& &1.num) |> Enum.sort()
      assert nums == [101, 103]
    end
  end
end
