defmodule EctoLibSql.TypeCompatibilityTest do
  use ExUnit.Case, async: false

  defmodule TestRepo do
    use Ecto.Repo, otp_app: :ecto_libsql, adapter: Ecto.Adapters.LibSql
  end

  defmodule Record do
    use Ecto.Schema
    import Ecto.Changeset

    schema "records" do
      field :bool_field, :boolean
      field :int_field, :integer
      field :float_field, :float
      field :string_field, :string
      field :map_field, :map
      field :array_field, {:array, :string}
      field :date_field, :date
      field :time_field, :time
      field :utc_datetime_field, :utc_datetime
      field :naive_datetime_field, :naive_datetime

      timestamps()
    end

    def changeset(record, attrs) do
      record
      |> cast(attrs, [
        :bool_field, :int_field, :float_field, :string_field,
        :map_field, :array_field, :date_field, :time_field,
        :utc_datetime_field, :naive_datetime_field
      ])
    end
  end

  @test_db "z_ecto_libsql_test-type_compat.db"

  setup_all do
    {:ok, _} = TestRepo.start_link(database: @test_db)

    Ecto.Adapters.SQL.query!(TestRepo, """
    CREATE TABLE IF NOT EXISTS records (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      bool_field INTEGER,
      int_field INTEGER,
      float_field REAL,
      string_field TEXT,
      map_field TEXT,
      array_field TEXT,
      date_field TEXT,
      time_field TEXT,
      utc_datetime_field TEXT,
      naive_datetime_field TEXT,
      inserted_at DATETIME,
      updated_at DATETIME
    )
    """)

    on_exit(fn ->
      EctoLibSql.TestHelpers.cleanup_db_files(@test_db)
    end)

    :ok
  end

  test "all field types round-trip correctly" do
    now_utc = DateTime.utc_now()
    now_naive = NaiveDateTime.utc_now()
    today = Date.utc_today()
    current_time = Time.new!(12, 30, 45)

    attrs = %{
      bool_field: true,
      int_field: 42,
      float_field: 3.14,
      string_field: "test",
      map_field: %{"key" => "value"},
      array_field: ["a", "b", "c"],
      date_field: today,
      time_field: current_time,
      utc_datetime_field: now_utc,
      naive_datetime_field: now_naive
    }

    # Insert
    changeset = Record.changeset(%Record{}, attrs)
    {:ok, inserted} = TestRepo.insert(changeset)

    IO.puts("\n=== Type Compatibility Test ===")
    IO.inspect(inserted, label: "Inserted record")

    # Verify inserted struct
    assert inserted.id != nil
    assert inserted.bool_field == true
    assert inserted.int_field == 42
    assert inserted.float_field == 3.14
    assert inserted.string_field == "test"
    assert inserted.map_field == %{"key" => "value"}
    assert inserted.array_field == ["a", "b", "c"]
    assert inserted.date_field == today
    assert inserted.time_field == current_time

    # Query back
    queried = TestRepo.get(Record, inserted.id)
    IO.inspect(queried, label: "Queried record")

    # Verify queried struct - all types should match
    assert queried.id == inserted.id
    assert queried.bool_field == true, "Boolean should roundtrip"
    assert queried.int_field == 42, "Integer should roundtrip"
    assert queried.float_field == 3.14, "Float should roundtrip"
    assert queried.string_field == "test", "String should roundtrip"
    assert queried.map_field == %{"key" => "value"}, "Map should roundtrip"
    assert queried.array_field == ["a", "b", "c"], "Array should roundtrip"
    assert queried.date_field == today, "Date should roundtrip"
    assert queried.time_field == current_time, "Time should roundtrip"

    IO.puts("✅ PASS: All types round-trip correctly")
  end
end
