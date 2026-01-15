defmodule EctoLibSql.DateTimeUsecTest do
  use ExUnit.Case, async: false

  # Test schemas with microsecond precision timestamps
  defmodule TestRepo do
    use Ecto.Repo,
      otp_app: :ecto_libsql,
      adapter: Ecto.Adapters.LibSql
  end

  defmodule Sale do
    use Ecto.Schema
    import Ecto.Changeset

    @timestamps_opts [type: :utc_datetime_usec]
    schema "sales" do
      field(:product_name, :string)
      field(:customer_name, :string)
      field(:amount, :decimal)
      field(:quantity, :integer)

      timestamps()
    end

    def changeset(sale, attrs) do
      sale
      |> cast(attrs, [:product_name, :customer_name, :amount, :quantity])
      |> validate_required([:product_name, :customer_name, :amount, :quantity])
    end
  end

  defmodule Event do
    use Ecto.Schema

    @timestamps_opts [type: :naive_datetime_usec]
    schema "events" do
      field(:name, :string)
      field(:occurred_at, :utc_datetime_usec)

      timestamps()
    end
  end

  setup_all do
    # Use unique per-run DB filename to avoid cross-run collisions.
    test_db = "z_ecto_libsql_test-datetime_usec_#{System.unique_integer([:positive])}.db"
    # Start the test repo
    {:ok, _} = TestRepo.start_link(database: test_db)

    # Create sales table
    Ecto.Adapters.SQL.query!(TestRepo, """
    CREATE TABLE IF NOT EXISTS sales (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      product_name TEXT NOT NULL,
      customer_name TEXT NOT NULL,
      amount DECIMAL NOT NULL,
      quantity INTEGER NOT NULL,
      inserted_at DATETIME,
      updated_at DATETIME
    )
    """)

    # Create events table
    Ecto.Adapters.SQL.query!(TestRepo, """
    CREATE TABLE IF NOT EXISTS events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      occurred_at DATETIME,
      inserted_at DATETIME,
      updated_at DATETIME
    )
    """)

    on_exit(fn ->
      EctoLibSql.TestHelpers.cleanup_db_files(test_db)
    end)

    :ok
  end

  setup do
    # Clean tables before each test
    Ecto.Adapters.SQL.query!(TestRepo, "DELETE FROM sales")
    Ecto.Adapters.SQL.query!(TestRepo, "DELETE FROM events")
    :ok
  end

  describe "utc_datetime_usec loading" do
    test "inserts and loads records with utc_datetime_usec timestamps" do
      # Insert a sale
      sale =
        %Sale{}
        |> Sale.changeset(%{
          product_name: "Widget",
          customer_name: "Alice",
          amount: Decimal.new("100.50"),
          quantity: 2
        })
        |> TestRepo.insert!()

      assert sale.id
      assert sale.product_name == "Widget"
      assert sale.customer_name == "Alice"
      assert %DateTime{} = sale.inserted_at
      assert %DateTime{} = sale.updated_at

      # Query the sale back
      loaded_sale = TestRepo.get!(Sale, sale.id)
      assert loaded_sale.product_name == "Widget"
      assert loaded_sale.customer_name == "Alice"
      assert %DateTime{} = loaded_sale.inserted_at
      assert %DateTime{} = loaded_sale.updated_at

      # Verify microsecond precision and values are preserved
      {inserted_usec, inserted_precision} = sale.inserted_at.microsecond
      {loaded_usec, loaded_precision} = loaded_sale.inserted_at.microsecond

      # Check precision is 6 (microseconds)
      assert inserted_precision == 6
      assert loaded_precision == 6

      # Check microsecond values are preserved (not truncated/zeroed)
      assert inserted_usec == loaded_usec
    end

    test "handles updates with utc_datetime_usec" do
      sale =
        %Sale{}
        |> Sale.changeset(%{
          product_name: "Gadget",
          customer_name: "Bob",
          amount: Decimal.new("250.00"),
          quantity: 5
        })
        |> TestRepo.insert!()

      # Wait a moment to ensure updated_at changes
      :timer.sleep(10)

      # Update the sale
      updated_sale =
        sale
        |> Sale.changeset(%{quantity: 10})
        |> TestRepo.update!()

      assert updated_sale.quantity == 10
      assert %DateTime{} = updated_sale.updated_at
      assert DateTime.compare(updated_sale.updated_at, sale.updated_at) == :gt
    end

    test "queries with all/2 return properly loaded utc_datetime_usec" do
      # Insert multiple sales
      Enum.each(1..3, fn i ->
        %Sale{}
        |> Sale.changeset(%{
          product_name: "Product #{i}",
          customer_name: "Customer #{i}",
          amount: Decimal.new("#{i}00.00"),
          quantity: i
        })
        |> TestRepo.insert!()
      end)

      # Query all sales
      sales = TestRepo.all(Sale)
      assert length(sales) == 3

      Enum.each(sales, fn sale ->
        assert %DateTime{} = sale.inserted_at
        assert %DateTime{} = sale.updated_at
      end)
    end
  end

  describe "naive_datetime_usec loading" do
    test "inserts and loads records with naive_datetime_usec timestamps" do
      event =
        TestRepo.insert!(%Event{
          name: "Test Event",
          occurred_at: DateTime.utc_now()
        })

      assert event.id
      assert event.name == "Test Event"
      assert %NaiveDateTime{} = event.inserted_at
      assert %NaiveDateTime{} = event.updated_at
      assert %DateTime{} = event.occurred_at

      # Query the event back
      loaded_event = TestRepo.get!(Event, event.id)
      assert loaded_event.name == "Test Event"
      assert %NaiveDateTime{} = loaded_event.inserted_at
      assert %NaiveDateTime{} = loaded_event.updated_at
      assert %DateTime{} = loaded_event.occurred_at
    end
  end

  describe "explicit datetime_usec fields" do
    test "loads utc_datetime_usec field values" do
      now = DateTime.utc_now()

      event =
        TestRepo.insert!(%Event{
          name: "Explicit Time Event",
          occurred_at: now
        })

      loaded_event = TestRepo.get!(Event, event.id)
      assert %DateTime{} = loaded_event.occurred_at

      # Verify microsecond precision and values are preserved
      {original_usec, original_precision} = now.microsecond
      {loaded_usec, loaded_precision} = loaded_event.occurred_at.microsecond

      # Check precision is 6 (microseconds)
      assert original_precision == 6
      assert loaded_precision == 6

      # Check microsecond values are preserved (not truncated/zeroed)
      assert original_usec == loaded_usec
    end
  end

  describe "raw query datetime_usec handling" do
    test "handles datetime strings from raw SQL queries" do
      # Insert via raw SQL with ISO 8601 datetime
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          TestRepo,
          "INSERT INTO sales (product_name, customer_name, amount, quantity, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
          [
            "Raw Product",
            "Raw Customer",
            "99.99",
            1,
            "2026-01-14T06:09:59.081609Z",
            "2026-01-14T06:09:59.081609Z"
          ]
        )

      # Query back using Ecto schema
      [sale] = TestRepo.all(Sale)
      assert sale.product_name == "Raw Product"
      assert %DateTime{} = sale.inserted_at
      assert %DateTime{} = sale.updated_at
    end
  end
end
