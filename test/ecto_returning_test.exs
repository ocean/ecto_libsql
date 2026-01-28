defmodule EctoLibSql.EctoReturningStructTest do
  use ExUnit.Case, async: false

  defmodule TestRepo do
    use Ecto.Repo, otp_app: :ecto_libsql, adapter: Ecto.Adapters.LibSql
  end

  defmodule User do
    use Ecto.Schema
    import Ecto.Changeset

    schema "users" do
      field(:name, :string)
      field(:email, :string)
      timestamps()
    end

    def changeset(user, attrs) do
      user
      |> cast(attrs, [:name, :email])
      |> validate_required([:name, :email])
    end
  end

  @test_db "z_ecto_libsql_test-ecto_returning.db"

  setup_all do
    {:ok, _} = TestRepo.start_link(database: @test_db)

    # Create table
    Ecto.Adapters.SQL.query!(TestRepo, """
    CREATE TABLE IF NOT EXISTS users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      email TEXT NOT NULL,
      inserted_at DATETIME,
      updated_at DATETIME
    )
    """)

    on_exit(fn ->
      EctoLibSql.TestHelpers.cleanup_db_files(@test_db)
    end)

    :ok
  end

  test "Repo.insert returns populated struct with id and timestamps" do
    changeset = User.changeset(%User{}, %{name: "Alice", email: "alice@example.com"})

    IO.puts("\n=== Test: INSERT RETURNING via Repo.insert ===")
    result = TestRepo.insert(changeset)

    IO.inspect(result, label: "Insert result")

    case result do
      {:ok, user} ->
        IO.inspect(user, label: "Returned user struct")

        # These assertions should pass if RETURNING struct mapping works
        assert user.id != nil, "❌ FAIL: ID is nil (struct mapping broken)"
        assert is_integer(user.id) and user.id > 0, "ID should be positive integer"
        assert user.name == "Alice", "Name should match"
        assert user.email == "alice@example.com", "Email should match"
        assert user.inserted_at != nil, "❌ FAIL: inserted_at is nil (timestamp conversion broken)"
        assert user.updated_at != nil, "❌ FAIL: updated_at is nil (timestamp conversion broken)"

        IO.puts("✅ PASS: Struct mapping and timestamp conversion working")
        :ok

      {:error, changeset} ->
        IO.inspect(changeset, label: "Error changeset")
        flunk("Insert failed: #{inspect(changeset)}")
    end
  end

  test "Multiple inserts return correctly populated structs" do
    results =
      for i <- 1..3 do
        user_data = %{
          name: "User#{i}",
          email: "user#{i}@example.com"
        }

        changeset = User.changeset(%User{}, user_data)
        {:ok, user} = TestRepo.insert(changeset)
        user
      end

    assert length(results) == 3

    Enum.each(results, fn user ->
      assert user.id != nil, "All users should have IDs"
      assert user.inserted_at != nil, "All users should have inserted_at"
      assert user.updated_at != nil, "All users should have updated_at"
    end)

    # IDs should be unique
    ids = Enum.map(results, & &1.id)
    assert length(Enum.uniq(ids)) == 3, "All IDs should be unique"

    IO.puts("✅ PASS: Multiple inserts return populated structs")
  end
end
