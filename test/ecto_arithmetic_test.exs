defmodule EctoLibSql.EctoArithmeticTest do
  @moduledoc """
  Coverage for arithmetic in query expressions.

  `expr/3` had no clause for `+`, `-`, `*` or `/`, so any arithmetic fell through to
  the catch-all that emits a bare "?". Nothing bound to that placeholder, so
  `where: s.count + 1 > 5` became `WHERE (? > 5)` and matched nothing, while
  `select: s.count + 1` returned nil. Neither raised.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  defmodule TestRepo do
    use Ecto.Repo, otp_app: :ecto_libsql, adapter: Ecto.Adapters.LibSql
  end

  defmodule Item do
    use Ecto.Schema

    schema "arithmetic_items" do
      field(:name, :string)
      field(:count, :integer)
    end
  end

  setup do
    unique_id = :erlang.unique_integer([:positive])
    test_db = "z_ecto_libsql_test-arithmetic-#{unique_id}.db"

    {:ok, pid} = TestRepo.start_link(database: test_db, pool_size: 1, name: TestRepo)

    Ecto.Adapters.SQL.query!(TestRepo, """
    CREATE TABLE IF NOT EXISTS arithmetic_items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT,
      count INTEGER
    )
    """)

    TestRepo.insert!(%Item{name: "ten", count: 10})
    TestRepo.insert!(%Item{name: "one", count: 1})

    on_exit(fn ->
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

  defp names(query), do: query |> TestRepo.all() |> Enum.sort()

  test "addition and subtraction filter on the computed value" do
    assert names(from(i in Item, where: i.count + 1 > 5, select: i.name)) == ["ten"]
    assert names(from(i in Item, where: i.count - 1 > 5, select: i.name)) == ["ten"]
    assert names(from(i in Item, where: i.count + 10 > 5, select: i.name)) == ["one", "ten"]
  end

  test "multiplication and division filter on the computed value" do
    assert names(from(i in Item, where: i.count * 2 > 5, select: i.name)) == ["ten"]
    assert names(from(i in Item, where: i.count * 10 > 5, select: i.name)) == ["one", "ten"]
    assert names(from(i in Item, where: i.count / 2 > 2, select: i.name)) == ["ten"]
  end

  test "arithmetic in a select returns the computed value" do
    assert TestRepo.all(from(i in Item, where: i.name == "ten", select: i.count + 1)) == [11]
    assert TestRepo.all(from(i in Item, where: i.name == "ten", select: i.count * 3)) == [30]
  end

  test "nested arithmetic keeps its precedence" do
    # (10 + 2) * 2 = 24, not 10 + (2 * 2) = 14.
    assert TestRepo.all(from(i in Item, where: i.name == "ten", select: (i.count + 2) * 2)) == [
             24
           ]
  end

  test "arithmetic against an interpolated value still binds as a parameter" do
    n = 5
    assert names(from(i in Item, where: i.count + ^n > 12, select: i.name)) == ["ten"]
  end

  test "arithmetic between two columns" do
    assert TestRepo.all(from(i in Item, where: i.name == "ten", select: i.count + i.count)) == [
             20
           ]
  end
end
