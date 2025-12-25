defmodule EctoLibSql.HooksTest do
  use ExUnit.Case, async: true

  alias EctoLibSql.Native

  setup do
    {:ok, state} = EctoLibSql.connect(database: ":memory:")

    on_exit(fn -> EctoLibSql.disconnect([], state) end)

    {:ok, state: state}
  end

  describe "add_update_hook/2 - NOT SUPPORTED" do
    test "returns :unsupported error", %{state: state} do
      assert :unsupported = Native.add_update_hook(state)
    end

    test "returns :unsupported with custom PID", %{state: state} do
      test_pid = self()
      assert :unsupported = Native.add_update_hook(state, test_pid)
    end

    test "does not affect database operations", %{state: state} do
      :unsupported = Native.add_update_hook(state)

      # Database operations should still work
      {:ok, _, _, _state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)",
          [],
          [],
          state
        )

      {:ok, _, _, _state} =
        EctoLibSql.handle_execute(
          "INSERT INTO users (name) VALUES ('Alice')",
          [],
          [],
          state
        )

      # No errors, no hook messages
    end
  end

  describe "remove_update_hook/1 - NOT SUPPORTED" do
    test "returns :unsupported error", %{state: state} do
      assert :unsupported = Native.remove_update_hook(state)
    end

    test "can be called multiple times safely", %{state: state} do
      assert :unsupported = Native.remove_update_hook(state)
      assert :unsupported = Native.remove_update_hook(state)
    end
  end

  describe "add_authorizer/2 - NOT SUPPORTED" do
    test "returns :unsupported error", %{state: state} do
      assert :unsupported = Native.add_authorizer(state)
    end

    test "returns :unsupported with custom PID", %{state: state} do
      test_pid = self()
      assert :unsupported = Native.add_authorizer(state, test_pid)
    end

    test "does not affect database operations", %{state: state} do
      :unsupported = Native.add_authorizer(state)

      # Database operations should still work
      {:ok, _, _, _state} =
        EctoLibSql.handle_execute(
          "CREATE TABLE posts (id INTEGER PRIMARY KEY, title TEXT)",
          [],
          [],
          state
        )

      {:ok, _, _, _state} =
        EctoLibSql.handle_execute(
          "INSERT INTO posts (title) VALUES ('Test Post')",
          [],
          [],
          state
        )

      # No errors
    end
  end
end
