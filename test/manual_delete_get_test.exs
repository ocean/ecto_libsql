defmodule ManualDeleteGetTest do
  use ExUnit.Case

  # Use the same test helpers as other integration tests
  alias Ecto.Integration.TestRepo
  import Ecto.Query

  defmodule User do
    use Ecto.Schema

    schema "manual_test_users" do
      field(:name, :string)
      field(:email, :string)
      field(:age, :integer)
      field(:active, :boolean, default: true)
    end
  end

  setup do
    # Create test table
    TestRepo.query!("""
    CREATE TABLE IF NOT EXISTS manual_test_users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      email TEXT NOT NULL,
      age INTEGER,
      active INTEGER DEFAULT 1
    )
    """)

    # Clean table before each test
    TestRepo.query!("DELETE FROM manual_test_users")

    on_exit(fn ->
      TestRepo.query!("DROP TABLE IF EXISTS manual_test_users")
    end)

    :ok
  end

  describe "Repo.get_by/3" do
    test "finds a record by a single field" do
      {:ok, alice} = TestRepo.insert(%User{name: "Alice", email: "alice@example.com", age: 30})
      {:ok, _bob} = TestRepo.insert(%User{name: "Bob", email: "bob@example.com", age: 25})

      # Find by email
      found = TestRepo.get_by(User, email: "alice@example.com")
      assert found != nil
      assert found.id == alice.id
      assert found.name == "Alice"
    end

    test "finds a record by multiple fields" do
      {:ok, alice} = TestRepo.insert(%User{name: "Alice", email: "alice@example.com", age: 30})
      {:ok, _bob} = TestRepo.insert(%User{name: "Bob", email: "bob@example.com", age: 25})

      # Find by name and age
      found = TestRepo.get_by(User, name: "Alice", age: 30)
      assert found != nil
      assert found.id == alice.id
    end

    test "returns nil when no record matches" do
      {:ok, _alice} = TestRepo.insert(%User{name: "Alice", email: "alice@example.com", age: 30})

      found = TestRepo.get_by(User, email: "nonexistent@example.com")
      assert found == nil
    end
  end

  describe "Repo.delete_all/2" do
    test "deletes all records matching a query" do
      {:ok, _alice} = TestRepo.insert(%User{name: "Alice", email: "alice@example.com", age: 30})
      {:ok, _bob} = TestRepo.insert(%User{name: "Bob", email: "bob@example.com", age: 25})

      {:ok, _charlie} =
        TestRepo.insert(%User{name: "Charlie", email: "charlie@example.com", age: 35})

      # Delete users aged 30 or more
      {count, _} =
        User
        |> where([u], u.age >= 30)
        |> TestRepo.delete_all()

      assert count == 2

      # Verify only Bob remains
      remaining = TestRepo.all(User)
      assert length(remaining) == 1
      assert hd(remaining).name == "Bob"
    end

    test "deletes all records when no conditions" do
      {:ok, _alice} = TestRepo.insert(%User{name: "Alice", email: "alice@example.com", age: 30})
      {:ok, _bob} = TestRepo.insert(%User{name: "Bob", email: "bob@example.com", age: 25})

      {count, _} = TestRepo.delete_all(User)
      assert count == 2

      remaining = TestRepo.all(User)
      assert length(remaining) == 0
    end

    test "returns 0 when no records match" do
      {:ok, _alice} = TestRepo.insert(%User{name: "Alice", email: "alice@example.com", age: 30})

      {count, _} =
        User
        |> where([u], u.age > 100)
        |> TestRepo.delete_all()

      assert count == 0
    end
  end
end
