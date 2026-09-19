defmodule EctoLibSql.EctoSandboxSavepointTest do
  @moduledoc """
  Coverage for `Ecto.Adapters.SQL.Sandbox`, which is how most Ecto applications run
  their entire test suite.

  The sandbox holds one transaction open for the duration of each test and rolls it
  back afterwards, so every `Repo.transaction/1` in application code runs nested and
  is issued with `mode: :savepoint`. If that mode is not honoured in `handle_begin/2`
  a plain BEGIN is issued inside the open transaction and SQLite rejects it with
  "cannot start a transaction within a transaction", which would leave no
  transactional application code testable at all.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox

  defmodule SandboxRepo do
    use Ecto.Repo, otp_app: :ecto_libsql, adapter: Ecto.Adapters.LibSql
  end

  defmodule Item do
    use Ecto.Schema

    schema "sandbox_items" do
      field(:num, :integer)
    end
  end

  setup do
    unique_id = :erlang.unique_integer([:positive])
    test_db = "z_ecto_libsql_test-sandbox_savepoint-#{unique_id}.db"

    {:ok, pid} =
      SandboxRepo.start_link(
        database: test_db,
        pool_size: 1,
        pool: Sandbox,
        name: SandboxRepo
      )

    Sandbox.mode(SandboxRepo, :manual)
    owner = Sandbox.start_owner!(SandboxRepo, shared: true)

    Ecto.Adapters.SQL.query!(SandboxRepo, """
    CREATE TABLE IF NOT EXISTS sandbox_items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      num INTEGER
    )
    """)

    on_exit(fn ->
      Sandbox.stop_owner(owner)

      # Process.alive?/1 is a point-in-time check: stopping the owner above can take
      # the repo supervisor down while we are still on this line, and Supervisor.stop/1
      # then exits with :noproc. Catch it rather than failing an otherwise passing test.
      if Process.alive?(pid) do
        try do
          :ok = Supervisor.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end

      Process.sleep(50)
      for f <- Path.wildcard(test_db <> "*"), do: File.rm(f)
    end)

    :ok
  end

  defp nums, do: SandboxRepo.all(from(i in Item, order_by: i.num, select: i.num))

  test "a transaction can be opened inside the sandbox transaction at all" do
    assert {:ok, :done} =
             SandboxRepo.transaction(fn ->
               SandboxRepo.insert!(%Item{num: 1})
               :done
             end)

    assert nums() == [1]
  end

  test "rolling back only discards work done inside the savepoint" do
    SandboxRepo.insert!(%Item{num: 1})

    assert {:error, :nope} =
             SandboxRepo.transaction(fn ->
               SandboxRepo.insert!(%Item{num: 2})
               SandboxRepo.rollback(:nope)
             end)

    # The write made before the savepoint survives, and the sandbox transaction is
    # still usable afterwards - which is the whole point of rolling back to a
    # savepoint rather than aborting the enclosing transaction.
    assert nums() == [1]
    SandboxRepo.insert!(%Item{num: 3})
    assert nums() == [1, 3]
  end

  test "an exception inside the transaction is contained the same way" do
    SandboxRepo.insert!(%Item{num: 1})

    assert_raise RuntimeError, "boom", fn ->
      SandboxRepo.transaction(fn ->
        SandboxRepo.insert!(%Item{num: 2})
        raise "boom"
      end)
    end

    assert nums() == [1]
  end
end
