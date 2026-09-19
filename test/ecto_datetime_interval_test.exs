defmodule EctoLibSql.EctoDatetimeIntervalTest do
  @moduledoc """
  Coverage for `ago/2` and `from_now/2`, which Ecto lowers to `datetime_add` and
  `date_add`.

  Neither had an `expr/3` clause, so both fell through to the catch-all that emits a
  bare "?" and the interval was dropped: `inserted_at > ago(14, "day")` became
  `inserted_at > ?` bound to the current time. Nothing raised - Ecto plans the
  parameters regardless of how many placeholders the adapter emits, and SQLite
  ignores an unreferenced one - so the comparison silently degraded to
  `column > now()` and rejected anything older than the current second while never
  enforcing the interval at all.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  defmodule TestRepo do
    use Ecto.Repo, otp_app: :ecto_libsql, adapter: Ecto.Adapters.LibSql
  end

  defmodule Event do
    use Ecto.Schema

    schema "interval_events" do
      field(:name, :string)
      field(:at, :utc_datetime)
      field(:on_date, :date)
    end
  end

  setup do
    unique_id = :erlang.unique_integer([:positive])
    test_db = "z_ecto_libsql_test-datetime_interval-#{unique_id}.db"

    {:ok, pid} = TestRepo.start_link(database: test_db, pool_size: 1, name: TestRepo)

    Ecto.Adapters.SQL.query!(TestRepo, """
    CREATE TABLE IF NOT EXISTS interval_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT,
      at TEXT,
      on_date TEXT
    )
    """)

    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          :ok = Supervisor.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end

      # Give SQLite time to release the file handles before removing them.
      Process.sleep(50)
      for f <- Path.wildcard(test_db <> "*"), do: File.rm(f)
    end)

    :ok
  end

  defp at!(name, amount, unit) do
    at = DateTime.add(DateTime.utc_now(:second), amount, unit)
    TestRepo.insert!(%Event{name: name, at: at})
  end

  defp names(query), do: query |> TestRepo.all() |> Enum.sort()

  describe "ago/2" do
    test "keeps rows inside the window and drops rows outside it" do
      at!("now", 0, :second)
      at!("day-13", -13, :day)
      at!("day-15", -15, :day)
      at!("year-ago", -365, :day)

      assert names(from(e in Event, where: e.at > ago(14, "day"), select: e.name)) ==
               ["day-13", "now"]
    end

    test "a row hours old is still inside a day-scale window" do
      at!("hours-ago", -6, :hour)

      # The bug made every window behave as `> now()`, so this vanished entirely.
      assert names(from(e in Event, where: e.at > ago(14, "day"), select: e.name)) ==
               ["hours-ago"]
    end

    test "minute and hour units resolve to their own scale" do
      at!("min-10", -10, :minute)
      at!("min-20", -20, :minute)

      assert names(from(e in Event, where: e.at > ago(15, "minute"), select: e.name)) ==
               ["min-10"]

      assert names(from(e in Event, where: e.at > ago(1, "hour"), select: e.name)) ==
               ["min-10", "min-20"]
    end

    test "week, millisecond and microsecond are converted to units SQLite has" do
      at!("day-3", -3, :day)
      at!("day-10", -10, :day)

      assert names(from(e in Event, where: e.at > ago(1, "week"), select: e.name)) == ["day-3"]

      at!("recent", -2, :second)

      assert names(from(e in Event, where: e.at > ago(5000, "millisecond"), select: e.name)) ==
               ["recent"]

      assert names(from(e in Event, where: e.at > ago(5_000_000, "microsecond"), select: e.name)) ==
               ["recent"]
    end

    test "an interpolated count still binds as a parameter" do
      at!("day-3", -3, :day)
      at!("day-10", -10, :day)

      days = 7
      query = from(e in Event, where: e.at > ago(^days, "day"), select: e.name)

      assert names(query) == ["day-3"]

      # The count is rendered through expr/3 rather than interpolated into the SQL,
      # so an interpolated value stays a bound parameter.
      {sql, _params} = Ecto.Adapters.SQL.to_sql(:all, TestRepo, query)
      assert sql =~ "strftime"
      assert sql =~ "days"
    end

    test "the interval reaches the SQL rather than being dropped" do
      {sql, _params} =
        Ecto.Adapters.SQL.to_sql(:all, TestRepo, from(e in Event, where: e.at > ago(14, "day")))

      assert sql =~ "strftime"
      assert sql =~ "days"
      refute sql =~ ~r/"at" > \?\s*\)/
    end
  end

  describe "from_now/2" do
    test "selects rows ahead of now" do
      at!("past", -1, :day)
      at!("soon", 60, :second)
      at!("later", 3, :day)

      assert names(from(e in Event, where: e.at < from_now(1, "day"), select: e.name)) ==
               ["past", "soon"]
    end
  end

  describe "date_add" do
    test "applies the interval to a date column" do
      today = Date.utc_today()
      TestRepo.insert!(%Event{name: "d-3", on_date: Date.add(today, -3)})
      TestRepo.insert!(%Event{name: "d-30", on_date: Date.add(today, -30)})

      assert names(from(e in Event, where: e.on_date > ago(7, "day"), select: e.name)) == ["d-3"]
    end
  end
end
