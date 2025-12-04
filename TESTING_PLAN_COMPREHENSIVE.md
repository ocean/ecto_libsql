# Comprehensive Testing Plan for libsql Feature Coverage

**Version**: 1.0.0
**Date**: 2025-12-04
**Target**: v1.0.0 (95% libsql feature coverage)
**Current Test Count**: 162 tests (v0.6.0)
**Target Test Count**: 300+ tests (v1.0.0)

---

## Executive Summary

This testing plan ensures **comprehensive coverage of all libsql features** implemented in ecto_libsql, with focus on:

1. ✅ **Core Features** - 95%+ coverage (CRUD, transactions, connections)
2. ✅ **Embedded Replica Sync** - 100% coverage (the killer feature)
3. ✅ **Performance** - Benchmarks for all critical paths
4. ✅ **Error Handling** - No panics, graceful degradation
5. ✅ **Integration** - All connection modes, all Elixir/OTP versions

**Testing Philosophy**: Test behaviour, not implementation. Focus on user-facing API.

---

## Test Organisation

### Current Test Files (v0.6.0)

```
test/
├── ecto_adapter_test.exs           # Storage operations, type loaders/dumpers
├── ecto_connection_test.exs        # SQL generation, DDL
├── ecto_integration_test.exs       # Full Ecto workflows (CRUD, associations)
├── ecto_libsql_test.exs            # DBConnection protocol
├── ecto_migration_test.exs         # Migration operations
├── error_handling_test.exs         # Error handling verification
└── turso_remote_test.exs           # Remote Turso tests (optional)

native/ecto_libsql/src/
└── tests.rs                        # Rust NIF unit tests
```

### Additional Test Files Needed (v0.7.0+)

```
test/
├── prepared_statement_test.exs     # Statement caching, reset, reuse
├── savepoint_test.exs              # Nested transactions, rollback
├── cursor_streaming_test.exs       # Large dataset streaming
├── replica_sync_test.exs           # Embedded replica sync features
├── hook_callback_test.exs          # Hooks (update, authoriser, commit/rollback)
├── extension_test.exs              # Extension loading
├── vector_search_test.exs          # Vector operations
├── performance_test.exs            # Benchmarks (using Benchee)
└── concurrent_access_test.exs      # Multi-process scenarios
```

---

## Phase 1 Tests: Fix Performance & Core Features (v0.7.0)

### 1.1 Prepared Statement Tests

**File**: `test/prepared_statement_test.exs`
**Target Coverage**: 100% of statement lifecycle
**Current Gap**: Statement reset not tested (doesn't exist yet)

#### Unit Tests

```elixir
defmodule EctoLibSql.PreparedStatementTest do
  use ExUnit.Case

  describe "statement preparation" do
    test "prepare statement returns statement ID"
    test "prepare duplicate SQL returns same statement ID"
    test "prepare invalid SQL returns error"
    test "prepare parameterised query with placeholders"
  end

  describe "statement execution" do
    test "execute prepared statement with parameters"
    test "execute prepared statement multiple times with different parameters"
    test "execute prepared statement without parameters"
    test "execute with wrong number of parameters returns error"
    test "execute with invalid parameter types returns error"
  end

  describe "statement reset and reuse" do
    test "reset statement clears bindings"
    test "reset allows re-execution with new parameters"
    test "reset does NOT re-prepare statement" # Critical!
    test "can execute → reset → execute multiple times"
  end

  describe "statement introspection" do
    test "column_count returns number of result columns"
    test "column_name returns column name by index"
    test "parameter_count returns number of parameters"
    test "column_name with invalid index returns error"
  end

  describe "statement lifecycle" do
    test "close statement removes from registry"
    test "close connection closes all statements"
    test "use after close returns error"
  end
end
```

#### Performance Tests

```elixir
defmodule EctoLibSql.PreparedStatementPerfTest do
  use ExUnit.Case

  @iterations 1000

  test "prepared statement with reset is faster than re-preparing" do
    # Setup
    {:ok, repo} = start_repo()
    {:ok, stmt} = Repo.prepare("INSERT INTO logs (msg) VALUES (?)")

    # Benchmark with reset
    time_with_reset = :timer.tc(fn ->
      for i <- 1..@iterations do
        Repo.execute_stmt(stmt, ["Message #{i}"])
        Repo.reset_stmt(stmt)
      end
    end) |> elem(0)

    # Benchmark with re-prepare
    time_with_reprepare = :timer.tc(fn ->
      for i <- 1..@iterations do
        {:ok, new_stmt} = Repo.prepare("INSERT INTO logs (msg) VALUES (?)")
        Repo.execute_stmt(new_stmt, ["Message #{i}"])
        Repo.close_stmt(new_stmt)
      end
    end) |> elem(0)

    # Reset should be at least 30% faster
    assert time_with_reset < time_with_reprepare * 0.7
  end

  test "statement execution memory usage stays constant" do
    # Execute 10,000 times, memory should not grow significantly
    {:ok, stmt} = Repo.prepare("SELECT ? + ?")

    initial_memory = :erlang.memory(:total)

    for i <- 1..10_000 do
      Repo.query_stmt(stmt, [i, i + 1])
      Repo.reset_stmt(stmt)
    end

    final_memory = :erlang.memory(:total)
    memory_growth = final_memory - initial_memory

    # Allow 10MB growth max (accounting for other processes)
    assert memory_growth < 10 * 1024 * 1024
  end
end
```

**Estimated Tests**: 18 tests (13 unit + 5 performance)

---

### 1.2 Savepoint Tests

**File**: `test/savepoint_test.exs`
**Target Coverage**: 100% of savepoint operations

#### Unit Tests

```elixir
defmodule EctoLibSql.SavepointTest do
  use ExUnit.Case

  describe "savepoint creation" do
    test "create savepoint in transaction"
    test "create nested savepoints (3 levels deep)"
    test "create savepoint with custom name"
    test "create duplicate savepoint name returns error"
    test "create savepoint outside transaction returns error"
  end

  describe "savepoint rollback" do
    test "rollback to savepoint preserves outer transaction"
    test "rollback to savepoint undoes changes after savepoint"
    test "rollback to savepoint allows continuing transaction"
    test "rollback to non-existent savepoint returns error"
    test "rollback middle savepoint preserves outer and inner"
  end

  describe "savepoint release" do
    test "release savepoint commits changes"
    test "release savepoint allows transaction commit"
    test "release non-existent savepoint returns error"
    test "release all savepoints then commit works"
  end

  describe "error scenarios" do
    test "error in savepoint rolls back to savepoint, not transaction"
    test "constraint violation in savepoint can be rolled back"
    test "multiple savepoint rollbacks work correctly"
  end
end
```

#### Integration Tests

```elixir
describe "complex savepoint scenarios" do
  test "nested savepoints with partial rollback" do
    Repo.transaction(fn ->
      Repo.insert(%User{name: "Alice"})  # Committed

      Repo.savepoint("sp1", fn ->
        Repo.insert(%User{name: "Bob"})  # Rolled back

        Repo.savepoint("sp2", fn ->
          Repo.insert(%User{name: "Charlie"})  # Rolled back
          Repo.rollback_to_savepoint("sp1")
        end)
      end)

      # Only Alice should exist
      assert Repo.aggregate(User, :count) == 1
    end)
  end

  test "savepoint for optional audit logging" do
    Repo.transaction(fn ->
      user = Repo.insert!(%User{name: "Alice"})

      # Try to log, but don't fail transaction if logging fails
      Repo.savepoint("audit", fn ->
        case Repo.insert(%AuditLog{user_id: user.id}) do
          {:ok, _log} -> Repo.release_savepoint("audit")
          {:error, _} -> Repo.rollback_to_savepoint("audit")
        end
      end)

      # User is inserted regardless of audit log success
      user
    end)
  end
end
```

**Estimated Tests**: 22 tests (16 unit + 6 integration)

---

### 1.3 Statement Introspection Tests

**File**: `test/prepared_statement_test.exs` (add to existing file)

```elixir
describe "column metadata" do
  test "SELECT returns correct column count" do
    {:ok, stmt} = Repo.prepare("SELECT id, name, email FROM users")
    assert EctoLibSql.statement_column_count(stmt) == {:ok, 3}
  end

  test "SELECT returns correct column names" do
    {:ok, stmt} = Repo.prepare("SELECT id, name FROM users")
    assert EctoLibSql.statement_column_name(stmt, 0) == {:ok, "id"}
    assert EctoLibSql.statement_column_name(stmt, 1) == {:ok, "name"}
  end

  test "SELECT * returns all column names" do
    Repo.query("CREATE TABLE test (a INT, b TEXT, c REAL)")
    {:ok, stmt} = Repo.prepare("SELECT * FROM test")

    assert EctoLibSql.statement_column_count(stmt) == {:ok, 3}
    assert EctoLibSql.statement_column_name(stmt, 0) == {:ok, "a"}
    assert EctoLibSql.statement_column_name(stmt, 1) == {:ok, "b"}
    assert EctoLibSql.statement_column_name(stmt, 2) == {:ok, "c"}
  end

  test "INSERT returns zero columns" do
    {:ok, stmt} = Repo.prepare("INSERT INTO users VALUES (?, ?)")
    assert EctoLibSql.statement_column_count(stmt) == {:ok, 0}
  end

  test "invalid column index returns error" do
    {:ok, stmt} = Repo.prepare("SELECT id FROM users")
    assert EctoLibSql.statement_column_name(stmt, 99) == {:error, _}
  end
end

describe "parameter metadata" do
  test "query with parameters returns correct count" do
    {:ok, stmt} = Repo.prepare("SELECT * FROM users WHERE id = ? AND name = ?")
    assert EctoLibSql.statement_parameter_count(stmt) == {:ok, 2}
  end

  test "query without parameters returns zero" do
    {:ok, stmt} = Repo.prepare("SELECT * FROM users")
    assert EctoLibSql.statement_parameter_count(stmt) == {:ok, 0}
  end

  test "complex query with many parameters" do
    {:ok, stmt} = Repo.prepare("INSERT INTO users VALUES (?, ?, ?, ?, ?)")
    assert EctoLibSql.statement_parameter_count(stmt) == {:ok, 5}
  end
end
```

**Estimated Tests**: 10 tests

---

### Phase 1 Total

**New Tests**: 50 tests
**Estimated Effort**: 5-6 days (tests + implementation)
**Coverage**: Statement lifecycle, savepoints, introspection

---

## Phase 2 Tests: Embedded Replica Features (v0.8.0)

### 2.1 Replica Sync Tests

**File**: `test/replica_sync_test.exs`
**Target Coverage**: 100% of sync features

#### Basic Sync Tests

```elixir
defmodule EctoLibSql.ReplicaSyncTest do
  use ExUnit.Case

  @moduletag :turso_remote  # Requires Turso credentials

  describe "basic sync" do
    test "manual sync pulls remote changes" do
      # Setup: Write to remote
      write_to_remote("INSERT INTO users VALUES (1, 'Alice')")

      # Local replica before sync shouldn't have data
      assert Repo.all(User) == []

      # Sync
      :ok = Repo.sync()

      # Now local has data
      assert length(Repo.all(User)) == 1
    end

    test "auto-sync on writes" do
      # Write locally (should auto-sync to remote)
      {:ok, user} = Repo.insert(%User{name: "Bob"})

      # Verify on remote immediately
      assert remote_query("SELECT * FROM users WHERE id = ?", [user.id])
    end

    test "sync with timeout succeeds" do
      # Large sync should complete within timeout
      write_to_remote_bulk(1000)

      assert {:ok, _} = Repo.sync(timeout: 30_000)
    end

    test "sync timeout returns error gracefully" do
      # Simulate slow network (mock)
      assert {:error, :timeout} = Repo.sync(timeout: 1)
    end
  end

  describe "advanced sync" do
    test "get_frame_number returns current frame" do
      initial_frame = Repo.get_frame_number()

      # Write data
      Repo.insert(%User{name: "Test"})

      # Frame should increase
      new_frame = Repo.get_frame_number()
      assert new_frame > initial_frame
    end

    test "sync_until waits for specific frame" do
      target_frame = Repo.get_frame_number() + 10

      # Write async on remote
      Task.async(fn ->
        write_to_remote_bulk(10)
      end)

      # Wait for frame
      :ok = Repo.sync_until(target_frame, timeout: 10_000)

      # Should be at or past target
      assert Repo.get_frame_number() >= target_frame
    end

    test "flush_replicator flushes pending writes" do
      # Write data
      Repo.insert_all(User, [%{name: "A"}, %{name: "B"}])

      # Flush
      {:ok, frame} = Repo.flush_replicator()

      # Frame should be current
      assert frame == Repo.get_frame_number()
    end
  end

  describe "freeze database" do
    test "freeze converts replica to standalone" do
      # Setup replica
      {:ok, repo} = start_replica()

      # Freeze
      :ok = EctoLibSql.freeze(repo)

      # Should be standalone now (can write without remote)
      {:ok, _} = Repo.insert(%User{name: "Local"})

      # Cannot sync after freeze
      assert {:error, _} = Repo.sync()
    end

    test "standalone can write after freeze" do
      {:ok, repo} = start_replica()
      :ok = EctoLibSql.freeze(repo)

      # Multiple writes work
      for i <- 1..100 do
        {:ok, _} = Repo.insert(%User{name: "User #{i}"})
      end

      assert Repo.aggregate(User, :count) == 100
    end
  end
end
```

#### Performance Tests

```elixir
describe "sync performance" do
  test "sync overhead under load" do
    # Measure write throughput with auto-sync
    time_with_sync = measure_insert_throughput(1000)

    # Measure write throughput local-only
    time_without_sync = measure_insert_throughput_local(1000)

    # Auto-sync overhead should be < 20%
    assert time_with_sync < time_without_sync * 1.2
  end

  test "concurrent reads during sync" do
    # Start long sync
    sync_task = Task.async(fn -> Repo.sync() end)

    # Reads should work during sync
    for _ <- 1..100 do
      assert length(Repo.all(User)) >= 0
    end

    Task.await(sync_task)
  end

  test "monitor replication lag" do
    # Write to remote
    remote_frame_before = get_remote_frame_number()
    write_to_remote_bulk(1000)
    remote_frame_after = get_remote_frame_number()

    # Local frame should be behind
    local_frame = Repo.get_frame_number()
    lag = remote_frame_after - local_frame

    # Sync should reduce lag to zero
    Repo.sync()
    assert Repo.get_frame_number() >= remote_frame_after
  end
end
```

**Estimated Tests**: 20 tests (13 unit + 7 performance)

---

### 2.2 Streaming Cursor Tests

**File**: `test/cursor_streaming_test.exs`
**Target Coverage**: 100% of cursor operations

```elixir
defmodule EctoLibSql.CursorStreamingTest do
  use ExUnit.Case

  describe "cursor declaration" do
    test "declare cursor for SELECT query"
    test "declare cursor with parameters"
    test "declare cursor on connection"
    test "declare cursor in transaction"
    test "declare multiple cursors simultaneously"
  end

  describe "cursor fetching" do
    test "fetch cursor returns batch of rows"
    test "fetch cursor with limit"
    test "fetch beyond end returns empty"
    test "fetch after close returns error"
  end

  describe "memory efficiency" do
    test "stream 1 million rows with constant memory" do
      # Insert 1M rows
      Repo.query("CREATE TABLE big (id INTEGER, data TEXT)")
      for i <- 1..1_000_000 do
        Repo.query("INSERT INTO big VALUES (?, ?)", [i, "data#{i}"])
      end

      # Declare cursor
      {:ok, cursor} = Repo.declare_cursor("SELECT * FROM big")

      # Measure memory before
      initial_memory = :erlang.memory(:total)

      # Fetch all (should stream, not load all)
      rows = []
      fetch_all_batches(cursor, rows)

      # Measure memory after
      final_memory = :erlang.memory(:total)
      memory_growth = final_memory - initial_memory

      # Should use < 100MB (not loading all rows)
      assert memory_growth < 100 * 1024 * 1024
    end

    test "cursor position advances correctly" do
      {:ok, cursor} = Repo.declare_cursor("SELECT * FROM users LIMIT 100")

      # Fetch first 10
      {:ok, {_cols, rows1, count1}} = Repo.fetch_cursor(cursor, 10)
      assert count1 == 10

      # Fetch next 10
      {:ok, {_cols, rows2, count2}} = Repo.fetch_cursor(cursor, 10)
      assert count2 == 10
      assert rows1 != rows2  # Different rows
    end
  end

  describe "cursor with Ecto stream" do
    test "Repo.stream uses cursor under the hood" do
      # This should use declare_cursor internally
      stream = Repo.stream(User, max_rows: 100)

      # Take only first 10, should not load all
      users = Enum.take(stream, 10)
      assert length(users) == 10
    end
  end
end
```

**Estimated Tests**: 15 tests

---

### Phase 2 Total

**New Tests**: 35 tests
**Estimated Effort**: 4-5 days
**Coverage**: Replica sync, advanced sync, streaming

---

## Phase 3 Tests: Hooks & Extensions (v0.9.0)

### 3.1 Hook Tests

**File**: `test/hook_callback_test.exs`

```elixir
defmodule EctoLibSql.HookCallbackTest do
  use ExUnit.Case

  describe "update hook" do
    test "receives INSERT notifications" do
      # Register hook
      parent = self()
      EctoLibSql.set_update_hook(Repo, fn action, _db, table, rowid ->
        send(parent, {:update, action, table, rowid})
      end)

      # Insert
      {:ok, user} = Repo.insert(%User{name: "Alice"})

      # Should receive notification
      assert_receive {:update, :insert, "users", rowid}
      assert rowid == user.id
    end

    test "receives UPDATE notifications"
    test "receives DELETE notifications"
    test "hook receives correct table name"
    test "remove hook stops notifications"
    test "hook error doesn't crash VM"

    test "hook overhead is acceptable" do
      # Measure insert time with hook
      EctoLibSql.set_update_hook(Repo, fn _, _, _, _ -> :ok end)
      time_with_hook = measure_bulk_insert(1000)

      # Measure without hook
      EctoLibSql.remove_update_hook(Repo)
      time_without_hook = measure_bulk_insert(1000)

      # Overhead should be < 10%
      assert time_with_hook < time_without_hook * 1.1
    end
  end

  describe "authoriser hook" do
    test "DENY blocks operation" do
      # Deny all writes
      EctoLibSql.set_authorizer(Repo, fn action, _table, _col, _ctx ->
        if action in [:insert, :update, :delete], do: :deny, else: :ok
      end)

      # Insert should fail
      assert {:error, _} = Repo.insert(%User{name: "Alice"})

      # Select should work
      assert Repo.all(User) == []
    end

    test "IGNORE hides column"
    test "OK allows operation"
    test "table-level access control"
    test "column-level access control"
    test "authoriser performance overhead"
  end

  describe "commit and rollback hooks" do
    test "commit hook called before commit"
    test "commit hook can block commit"
    test "rollback hook called on rollback"
    test "rollback hook error doesn't crash VM"
  end
end
```

**Estimated Tests**: 20 tests

---

### 3.2 Extension Tests

**File**: `test/extension_test.exs`

```elixir
defmodule EctoLibSql.ExtensionTest do
  use ExUnit.Case

  describe "load extension" do
    test "loads FTS5 extension" do
      # May already be built-in, verify first
      :ok = EctoLibSql.load_extension(Repo, "fts5")

      # FTS5 functions should work
      Repo.query("CREATE VIRTUAL TABLE docs USING fts5(content)")
      Repo.query("INSERT INTO docs VALUES ('searchable text')")

      {:ok, result} = Repo.query("SELECT * FROM docs WHERE docs MATCH 'searchable'")
      assert length(result.rows) == 1
    end

    test "load non-existent extension returns error"
    test "load extension with entry point"
    test "extension unloads on connection close"
    test "security: reject non-whitelisted extension paths"
  end

  describe "custom scalar functions" do
    test "register scalar function" do
      EctoLibSql.create_scalar_function(Repo, "add_ten", 1, fn x ->
        x + 10
      end)

      {:ok, result} = Repo.query("SELECT add_ten(5)")
      assert result.rows == [[15]]
    end

    test "scalar function with multiple arguments"
    test "scalar function with type conversion"
    test "scalar function error handling"
  end

  describe "custom aggregate functions" do
    test "register aggregate function" do
      EctoLibSql.create_aggregate_function(Repo, "my_sum", 1, %{
        init: fn -> 0 end,
        step: fn acc, value -> acc + value end,
        finalize: fn acc -> acc end
      })

      Repo.query("INSERT INTO numbers VALUES (1), (2), (3)")
      {:ok, result} = Repo.query("SELECT my_sum(value) FROM numbers")
      assert result.rows == [[6]]
    end
  end
end
```

**Estimated Tests**: 15 tests

---

### Phase 3 Total

**New Tests**: 35 tests
**Estimated Effort**: 5-6 days
**Coverage**: Hooks, extensions, custom functions

---

## Phase 4 Tests: Polish & Performance (v1.0.0)

### 4.1 Performance Benchmark Suite

**File**: `test/performance_test.exs` (using Benchee)

```elixir
defmodule EctoLibSql.PerformanceTest do
  use ExUnit.Case

  @tag :benchmark
  @tag timeout: 300_000  # 5 minutes

  test "comprehensive performance benchmark" do
    Benchee.run(
      %{
        "insert (prepared)" => fn -> insert_with_prepared() end,
        "insert (re-prepare)" => fn -> insert_with_reprepare() end,
        "select (small)" => fn -> select_100_rows() end,
        "select (large)" => fn -> select_10k_rows() end,
        "transaction (simple)" => fn -> simple_transaction() end,
        "transaction (nested savepoints)" => fn -> nested_savepoints() end,
        "batch (manual)" => fn -> manual_batch_100() end,
        "batch (native)" => fn -> native_batch_100() end,
        "cursor (buffered)" => fn -> cursor_fetch_all_buffered() end,
        "cursor (streaming)" => fn -> cursor_fetch_all_streaming() end,
        "sync (replica)" => fn -> replica_sync() end,
      },
      time: 10,
      memory_time: 2
    )
  end

  test "compare with ecto_sqlite3" do
    # Benchmark head-to-head with ecto_sqlite3
    Benchee.run(
      %{
        "ecto_libsql" => fn -> bulk_insert_libsql(1000) end,
        "ecto_sqlite3" => fn -> bulk_insert_sqlite3(1000) end,
      },
      time: 10
    )

    # ecto_libsql should be within 10% of ecto_sqlite3
  end
end
```

**Estimated Tests**: 10 benchmark suites

---

### 4.2 Concurrent Access Tests

**File**: `test/concurrent_access_test.exs`

```elixir
defmodule EctoLibSql.ConcurrentAccessTest do
  use ExUnit.Case

  describe "concurrent reads" do
    test "1000 concurrent reads" do
      tasks = for _ <- 1..1000 do
        Task.async(fn -> Repo.all(User) end)
      end

      results = Task.await_many(tasks, 30_000)
      assert length(results) == 1000
    end
  end

  describe "concurrent writes" do
    test "100 concurrent writes with busy_timeout" do
      Repo.set_busy_timeout(5000)

      tasks = for i <- 1..100 do
        Task.async(fn -> Repo.insert(%User{name: "User #{i}"}) end)
      end

      results = Task.await_many(tasks, 60_000)
      assert length(results) == 100
      assert Enum.all?(results, &match?({:ok, _}, &1))
    end

    test "reader-writer concurrency" do
      # 50 writers + 50 readers
      writers = for i <- 1..50 do
        Task.async(fn -> Repo.insert(%User{name: "Writer #{i}"}) end)
      end

      readers = for _ <- 1..50 do
        Task.async(fn -> Repo.all(User) end)
      end

      Task.await_many(writers ++ readers, 60_000)

      # All operations should succeed
    end
  end

  describe "connection pool exhaustion" do
    test "handles pool exhaustion gracefully" do
      # Configure small pool
      pool_size = 5

      # Try to use more connections than pool size
      tasks = for i <- 1..20 do
        Task.async(fn ->
          # Hold connection for 1 second
          Repo.transaction(fn ->
            Repo.insert(%User{name: "User #{i}"})
            Process.sleep(1000)
          end)
        end)
      end

      # All should eventually succeed (queue and wait)
      results = Task.await_many(tasks, 60_000)
      assert Enum.all?(results, &match?({:ok, _}, &1))
    end
  end
end
```

**Estimated Tests**: 12 tests

---

### Phase 4 Total

**New Tests**: 22 tests
**Estimated Effort**: 3-4 days
**Coverage**: Performance, concurrency, stress testing

---

## Test Coverage Summary

| Phase | Feature Area | Test Count | Coverage Target |
|-------|--------------|------------|-----------------|
| **Current (v0.6.0)** | Core features | 162 | 85% |
| **Phase 1 (v0.7.0)** | Statements, savepoints | +50 | 90% |
| **Phase 2 (v0.8.0)** | Replica sync, streaming | +35 | 92% |
| **Phase 3 (v0.9.0)** | Hooks, extensions | +35 | 94% |
| **Phase 4 (v1.0.0)** | Performance, concurrency | +22 | 95% |
| **TOTAL (v1.0.0)** | All features | **304** | **95%** |

---

## Testing Infrastructure

### Required Test Dependencies

```elixir
# mix.exs
defp deps do
  [
    # Existing
    {:ecto, "~> 3.11"},
    {:ecto_sql, "~> 3.11"},
    {:ex_unit, "~> 1.17", only: :test},

    # Add for comprehensive testing
    {:benchee, "~> 1.3", only: :test},
    {:stream_data, "~> 1.1", only: :test},  # Property-based testing
    {:ex_machina, "~> 2.8", only: :test},    # Factories
    {:mock, "~> 0.3", only: :test},           # Mocking
  ]
end
```

### Test Configuration

```elixir
# config/test.exs
config :ecto_libsql, EctoLibSql.TestRepo,
  database: ":memory:",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10,
  busy_timeout: 5000

# Turso remote tests (optional)
config :ecto_libsql, :turso_test,
  enabled: System.get_env("TURSO_TEST_ENABLED") == "true",
  url: System.get_env("TURSO_TEST_URL"),
  auth_token: System.get_env("TURSO_TEST_TOKEN")
```

### CI/CD Test Matrix

```yaml
# .github/workflows/ci.yml
strategy:
  matrix:
    elixir: ['1.17', '1.18']
    otp: ['26', '27']
    os: [ubuntu-latest, macos-latest]
    test-suite:
      - unit
      - integration
      - performance
      - turso-remote
```

---

## Test Execution Strategy

### Local Development

```bash
# Fast: Core tests only
mix test --exclude turso_remote --exclude benchmark

# Full: All tests
mix test

# Performance: Benchmarks
mix test --only benchmark

# Turso: Remote tests (requires credentials)
TURSO_TEST_ENABLED=true mix test --only turso_remote
```

### CI/CD Pipeline

```bash
# Stage 1: Fast unit tests (< 2 min)
mix test --exclude integration --exclude benchmark --exclude turso_remote

# Stage 2: Integration tests (< 5 min)
mix test --only integration

# Stage 3: Performance benchmarks (< 10 min)
mix test --only benchmark

# Stage 4: Turso remote tests (if secrets available)
mix test --only turso_remote
```

---

## Success Metrics

### Code Coverage

- ✅ **Core Features**: > 95% line coverage
- ✅ **Error Paths**: > 90% branch coverage
- ✅ **Integration**: All user-facing APIs tested
- ✅ **Performance**: All critical paths benchmarked

### Test Quality

- ✅ **Fast**: Unit tests < 5 seconds total
- ✅ **Reliable**: No flaky tests
- ✅ **Isolated**: Each test independent
- ✅ **Clear**: Descriptive test names

### Documentation

- ✅ **Test Coverage Badge**: In README.md
- ✅ **Performance Baselines**: Documented in PERFORMANCE.md
- ✅ **Test Organization**: Clear file structure
- ✅ **Example Usage**: Tests serve as examples

---

## Maintenance Plan

### After Each Phase

1. Review test coverage report
2. Add missing test cases
3. Refactor slow tests
4. Update test documentation

### Quarterly

1. Review and update benchmarks
2. Add tests for newly discovered edge cases
3. Update test dependencies
4. Performance regression testing

### Annually

1. Comprehensive test suite audit
2. Remove obsolete tests
3. Update test infrastructure
4. Benchmark against latest Elixir/OTP

---

## Conclusion

This testing plan ensures **comprehensive coverage** of all libsql features with focus on:

1. ✅ **100% of production-critical features** (statements, transactions, sync)
2. ✅ **Performance verification** (benchmarks for all critical paths)
3. ✅ **Error handling** (no panics, graceful degradation)
4. ✅ **Integration testing** (all connection modes, all Elixir versions)

**Target**: 304 tests with 95% coverage by v1.0.0 (May 2026)

---

**Document Version**: 1.0.0
**Date**: 2025-12-04
**Next Review**: After v0.7.0 release (January 2026)
