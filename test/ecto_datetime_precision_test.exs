defmodule EctoLibSql.EctoDatetimePrecisionTest do
  @moduledoc """
  Coverage for the precision guard on `ago/2` and `from_now/2`.

  SQLite's date and time functions parse to millisecond precision, so a cutoff built
  by `datetime_add`/`date_add` cannot carry the microseconds a `*_usec` column
  stores. Rather than filtering such rows incorrectly near the cutoff second, the
  adapter rejects the comparison. Second-precision columns are exact and keep
  working, and comparisons that do not involve a shifted datetime are untouched.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  defmodule TestRepo do
    use Ecto.Repo, otp_app: :ecto_libsql, adapter: Ecto.Adapters.LibSql
  end

  defmodule Event do
    use Ecto.Schema

    schema "precision_events" do
      field(:name, :string)
      field(:at, :utc_datetime)
      field(:at_naive, :naive_datetime)
      field(:at_usec, :utc_datetime_usec)
      field(:at_naive_usec, :naive_datetime_usec)
    end
  end

  setup do
    db = "z_ecto_libsql_test-precision-#{:erlang.unique_integer([:positive])}.db"
    {:ok, pid} = TestRepo.start_link(database: db, pool_size: 1, name: TestRepo)

    Ecto.Adapters.SQL.query!(TestRepo, """
    CREATE TABLE IF NOT EXISTS precision_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT, at TEXT, at_naive TEXT, at_usec TEXT, at_naive_usec TEXT
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

      Process.sleep(50)
      for f <- Path.wildcard(db <> "*"), do: File.rm(f)
    end)

    :ok
  end

  defp to_sql(query), do: Ecto.Adapters.SQL.to_sql(:all, TestRepo, query)

  describe "microsecond columns are rejected" do
    test "utc_datetime_usec compared with ago/2 raises" do
      assert_raise ArgumentError, ~r/:utc_datetime_usec.*ago\/2/s, fn ->
        to_sql(from(e in Event, where: e.at_usec > ago(14, "day")))
      end
    end

    test "naive_datetime_usec compared with ago/2 raises" do
      assert_raise ArgumentError, ~r/:naive_datetime_usec/, fn ->
        to_sql(from(e in Event, where: e.at_naive_usec > ago(14, "day")))
      end
    end

    test "from_now/2 is rejected the same way" do
      assert_raise ArgumentError, ~r/:utc_datetime_usec/, fn ->
        to_sql(from(e in Event, where: e.at_usec < from_now(1, "day")))
      end
    end

    test "the message explains the cause and the way out" do
      error =
        assert_raise ArgumentError, fn ->
          to_sql(from(e in Event, where: e.at_usec > ago(1, "day")))
        end

      assert error.message =~ "millisecond precision"
      assert error.message =~ ":utc_datetime"
    end

    test "rejection applies on either side of the comparison" do
      assert_raise ArgumentError, ~r/:utc_datetime_usec/, fn ->
        to_sql(from(e in Event, where: ago(14, "day") < e.at_usec))
      end
    end
  end

  describe "second-precision columns still work" do
    test "utc_datetime compares without raising and filters correctly" do
      now = DateTime.utc_now(:second)
      TestRepo.insert!(%Event{name: "recent", at: DateTime.add(now, -3, :day)})
      TestRepo.insert!(%Event{name: "old", at: DateTime.add(now, -30, :day)})

      names =
        from(e in Event, where: e.at > ago(14, "day"), select: e.name)
        |> TestRepo.all()
        |> Enum.sort()

      assert names == ["recent"]
    end

    test "naive_datetime compares without raising and filters correctly" do
      now = NaiveDateTime.utc_now(:second)
      TestRepo.insert!(%Event{name: "recent", at_naive: NaiveDateTime.add(now, -3, :day)})
      TestRepo.insert!(%Event{name: "old", at_naive: NaiveDateTime.add(now, -30, :day)})

      names =
        from(e in Event, where: e.at_naive > ago(14, "day"), select: e.name)
        |> TestRepo.all()
        |> Enum.sort()

      assert names == ["recent"]
    end
  end

  describe "the guard is scoped to shifted datetimes" do
    test "a usec column compared against a plain bound value is unaffected" do
      # Both sides are dumped by datetime_encode/1 in the same shape here, so the
      # text comparison is exact and there is nothing to reject.
      at = DateTime.utc_now()
      TestRepo.insert!(%Event{name: "a", at_usec: at})

      cutoff = DateTime.add(at, -1, :day)

      names =
        from(e in Event, where: e.at_usec > ^cutoff, select: e.name)
        |> TestRepo.all()

      assert names == ["a"]
    end

    test "a usec column in a non-comparison expression is unaffected" do
      TestRepo.insert!(%Event{name: "a", at_usec: DateTime.utc_now()})
      TestRepo.insert!(%Event{name: "b"})

      names =
        from(e in Event, where: is_nil(e.at_usec), select: e.name)
        |> TestRepo.all()

      assert names == ["b"]
    end

    test "non-datetime comparisons are unaffected" do
      TestRepo.insert!(%Event{name: "a"})
      assert [_] = TestRepo.all(from(e in Event, where: e.name == "a", select: e.id))
    end
  end
end
