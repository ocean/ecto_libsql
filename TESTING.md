# EctoLibSql Testing Guide

This document explains the comprehensive testing strategy for EctoLibSql, covering both the Rust NIF layer and the Elixir layer. This guide is for **developers working on the ecto_libsql library itself**.

> **Note**: If you're looking for guidance on testing applications that **use** ecto_libsql, see [USAGE.md](USAGE.md) instead.

## Table of Contents

- [Testing Architecture](#testing-architecture)
- [Test Organisation](#test-organisation)
- [Rust Tests](#rust-tests)
- [Elixir Tests](#elixir-tests)
- [Running Tests](#running-tests)
- [Test Coverage Summary](#test-coverage-summary)
- [Writing Tests](#writing-tests)
- [Debugging Tests](#debugging-tests)
- [CI/CD Integration](#cicd-integration)
- [Best Practices](#best-practices)

---

## Testing Architecture

EctoLibSql uses a **multi-layer testing approach**:

```
┌─────────────────────────────────────┐
│  Elixir Integration Tests           │  ← Test Ecto adapter with real schemas
├─────────────────────────────────────┤
│  Elixir Unit Tests                  │  ← Test Ecto DDL generation, type conversion
├─────────────────────────────────────┤
│  Elixir DBConnection Tests          │  ← Test basic connection/query operations
├─────────────────────────────────────┤
│  Rust Integration Tests             │  ← Test libSQL operations with real DB
├─────────────────────────────────────┤
│  Rust Unit Tests                    │  ← Test pure functions (query parsing, etc.)
└─────────────────────────────────────┘
```

---

## Test Organisation

Following Rust best practices, test code has been separated from the main implementation into its own module file.

### File Structure

```
native/ecto_libsql/src/
├── lib.rs              # Main NIF implementation (1,201 lines)
└── tests.rs            # All test code (463 lines)

test/
├── ecto_adapter_test.exs        # Ecto adapter functionality
├── ecto_connection_test.exs     # SQL generation & DDL
├── ecto_integration_test.exs    # Full Ecto workflows
├── ecto_libsql_test.exs         # DBConnection protocol
├── ecto_migration_test.exs      # Migration operations
├── error_handling_test.exs      # Error handling verification
└── turso_remote_test.exs        # Remote Turso tests (optional)
```

### Benefits of Separation

**Before Refactoring:**
- Single `lib.rs` file: 1,656+ lines (implementation + tests)
- Mixed production and test code
- Harder to navigate

**After Refactoring:**
- `lib.rs`: 1,201 lines (27% reduction)
- `tests.rs`: 463 lines (organized by category)
- Clear separation of concerns
- Standard Rust project structure

**Advantages:**
1. ✅ Production code is focused and easier to navigate
2. ✅ Tests are grouped logically by functionality
3. ✅ Follows Rust community conventions
4. ✅ Better for code review (smaller files)
5. ✅ Cleaner git diffs (implementation vs test changes)

---

## Rust Tests

### Location

All Rust tests are in `native/ecto_libsql/src/tests.rs`

### Test Modules

The `tests.rs` file is organized into three logical test suites:

#### 1. Query Type Detection Tests (`query_type_detection`)

Tests the `detect_query_type()` function which identifies SQL query types.

**Coverage:**
- SELECT, INSERT, UPDATE, DELETE queries
- DDL queries (CREATE, ALTER, DROP)
- Transaction queries (BEGIN, COMMIT, ROLLBACK)
- Edge cases (whitespace, case-insensitivity, unknown queries)

**Example:**
```rust
#[test]
fn test_detect_select_query() {
    assert_eq!(detect_query_type("SELECT * FROM users"), QueryType::Select);
    assert_eq!(detect_query_type("  select id from posts"), QueryType::Select);
}
```

**Tests:**
- `test_detect_select_query` - SELECT statements
- `test_detect_insert_query` - INSERT statements
- `test_detect_update_query` - UPDATE statements
- `test_detect_delete_query` - DELETE statements
- `test_detect_ddl_queries` - CREATE, DROP, ALTER
- `test_detect_transaction_queries` - BEGIN, COMMIT, ROLLBACK
- `test_detect_unknown_query` - PRAGMA, EXPLAIN, etc.
- `test_detect_with_whitespace` - Queries with leading whitespace

#### 2. Integration Tests (`integration_tests`)

Tests real database operations using libSQL's async API with temporary SQLite files.

**Coverage:**
- Database creation (local mode)
- Parameter binding (integers, floats, text, blobs, nulls)
- Transactions (commit, rollback)
- Prepared statements with different parameters
- Data type handling

**Example:**
```rust
#[tokio::test]
async fn test_parameter_binding_with_floats() {
    let db_path = setup_test_db();
    let db = Builder::new_local(&db_path).build().await.unwrap();
    let conn = db.connect().unwrap();

    conn.execute(
        "CREATE TABLE products (id INTEGER, price REAL)",
        vec![]
    ).await.unwrap();

    conn.execute(
        "INSERT INTO products (id, price) VALUES (?1, ?2)",
        vec![Value::Integer(1), Value::Real(19.99)]
    ).await.unwrap();

    // Verify the float was stored correctly
    let mut rows = conn.query("SELECT price FROM products WHERE id = 1", vec![])
        .await.unwrap();
    
    cleanup_test_db(&db_path);
}
```

**Key Tests:**
- `test_create_local_database` - Database creation
- `test_parameter_binding_with_integers` - Integer params
- `test_parameter_binding_with_floats` - Float params (critical bug fix verification)
- `test_parameter_binding_with_text` - String params
- `test_transaction_commit` - Transaction commit behaviour
- `test_transaction_rollback` - Transaction rollback behaviour
- `test_prepared_statement` - Prepared statement reuse
- `test_blob_storage` - Binary data handling
- `test_null_values` - NULL value handling

**Helper Functions:**
- `setup_test_db()` - Creates temp database with unique UUID name
- `cleanup_test_db()` - Removes test database files and handles cleanup

#### 3. Registry Tests (`registry_tests`)

Tests the thread-safe registry infrastructure used for managing connections, transactions, statements, and cursors.

**Coverage:**
- UUID generation uniqueness
- Registry initialization and accessibility
- Thread safety (implicit through Mutex usage)

**Tests:**
- `test_uuid_generation` - UUID uniqueness and format
- `test_registry_initialization` - Registry accessibility

### Limitations of Rust NIF Testing

Some aspects are **difficult to test directly in Rust**:

1. **NIF Functions** - Require Rustler's `Env` and `Term` types (only available from Elixir)
2. **Registry Cleanup** - Full lifecycle testing requires BEAM integration
3. **Mode Detection** - Requires Elixir atoms
4. **Error Propagation** - How errors surface to Elixir

**Solution:** These are tested at the **Elixir layer** instead.

---

## Elixir Tests

### Test Files

#### 1. `test/ecto_adapter_test.exs`

Tests the `Ecto.Adapters.LibSql` adapter implementation.

**Coverage:**
- `storage_up/1` - Database creation
- `storage_down/1` - Database deletion
- `storage_status/1` - Check database existence
- Type loaders (boolean, datetime, date, time)
- Type dumpers (boolean, datetime, date, time, binary)
- Remote-only mode edge cases

**Example:**
```elixir
test "loads boolean values correctly" do
  loader = Ecto.Adapters.LibSql.loaders(:boolean, :boolean) |> List.first()
  assert {:ok, false} == loader.(0)
  assert {:ok, true} == loader.(1)
end
```

#### 2. `test/ecto_connection_test.exs`

Tests `Ecto.Adapters.LibSql.Connection` for SQL generation and DDL operations.

**Coverage:**
- DDL generation (CREATE/DROP TABLE, ALTER TABLE)
- Index creation (regular, unique, partial, composite)
- Column type mapping (Ecto types → SQLite types)
- Constraint conversion (UNIQUE, FOREIGN KEY, CHECK)
- Edge cases (rename operations, IF EXISTS clauses)

**Example:**
```elixir
test "creates table with composite primary key" do
  table = %Table{name: :user_roles}
  columns = [
    {:add, :user_id, :integer, [primary_key: true]},
    {:add, :role_id, :integer, [primary_key: true]}
  ]

  [sql] = Connection.execute_ddl({:create, table, columns})
  assert sql =~ ~s[PRIMARY KEY ("user_id", "role_id")]
end
```

#### 3. `test/ecto_integration_test.exs`

**Full end-to-end integration tests** with real Ecto repos and schemas.

**Coverage:**
- CRUD operations (insert, read, update, delete)
- Advanced queries (filtering, ordering, LIKE, aggregations)
- Associations (has_many, belongs_to, preloading)
- Transactions (commit, rollback, explicit rollback)
- Batch operations (insert_all, update_all, delete_all)
- Type handling (boolean, datetime, decimal, text)
- Constraints (unique, not null, foreign key)
- Streaming large datasets

**Example:**
```elixir
test "preload user posts" do
  {:ok, user} = TestRepo.insert(%User{name: "Alice", email: "alice@example.com"})
  {:ok, _post1} = TestRepo.insert(%Post{title: "Post 1", body: "Body 1", user_id: user.id})
  {:ok, _post2} = TestRepo.insert(%Post{title: "Post 2", body: "Body 2", user_id: user.id})

  user_with_posts = User |> TestRepo.get(user.id) |> TestRepo.preload(:posts)
  assert length(user_with_posts.posts) == 2
end
```

#### 4. `test/ecto_libsql_test.exs`

Tests the DBConnection protocol implementation.

**Coverage:**
- Connection lifecycle
- Query execution
- Transaction handling
- Cursor operations

#### 5. `test/ecto_migration_test.exs`

Tests migration operations and DDL execution.

**Coverage:**
- Migration execution
- Schema changes
- Index management

#### 6. `test/error_handling_test.exs`

Tests error handling and graceful degradation (critical for v0.5.0+).

**Coverage:**
- Invalid connection IDs return errors (not panics)
- Invalid transaction IDs return errors
- Resource not found scenarios
- Mutex error handling
- VM stability verification

**Example:**
```elixir
test "query with non-existent connection ID returns error" do
  fake_conn_id = "00000000-0000-0000-0000-000000000000"
  result = EctoLibSql.Native.query_args(fake_conn_id, :local, :disable_sync, "SELECT 1", [])

  assert {:error, error_msg} = result
  assert error_msg =~ "Connection"
end
```

#### 7. `test/turso_remote_test.exs`

Tests remote Turso database operations (requires credentials).

**Coverage:**
- Remote connections
- Embedded replica sync
- Cloud operations

---

## Running Tests

### Rust Tests

```bash
# Run all Rust tests
cd native/ecto_libsql && cargo test

# Run with output
cargo test -- --nocapture

# Run specific test module
cargo test query_type_detection

# Run specific test
cargo test test_parameter_binding_with_floats

# Show backtraces
RUST_BACKTRACE=1 cargo test

# Static analysis
cargo check
cargo clippy
```

**Expected Output:**
```
running 19 tests
test tests::query_type_detection::test_detect_select_query ... ok
test tests::integration_tests::test_create_local_database ... ok
test tests::registry_tests::test_uuid_generation ... ok
...
test result: ok. 19 passed; 0 failed; 0 ignored
```

### Elixir Tests

```bash
# Run all Elixir tests
mix test

# Run specific test file
mix test test/ecto_adapter_test.exs

# Run specific test (by line number)
mix test test/ecto_integration_test.exs:123

# Run with detailed output
mix test --trace

# Run with coverage
mix test --cover

# Exclude Turso remote tests (don't have credentials)
mix test --exclude turso_remote

# Debug with IEx
iex -S mix test --trace
```

**Expected Output:**
```
Compiling 8 files (.ex)
Generated ecto_libsql app
...
118 tests, 0 failures, 21 skipped

Finished in 5.2 seconds (3.8s async, 1.4s sync)
```

### Both Test Suites

```bash
# Run both Rust and Elixir tests
cd native/ecto_libsql && cargo test && cd ../.. && mix test

# Check formatting (required before commit)
mix format --check-formatted

# Full verification
cd native/ecto_libsql && cargo test && cargo clippy && cd ../.. && mix test && mix format --check-formatted
```

---

## Test Coverage Summary

| Layer | What's Tested | Test Type | Location |
|-------|---------------|-----------|----------|
| **Rust Pure Functions** | Query type detection, UUID generation | Unit | `tests.rs` |
| **Rust Database Ops** | Connections, queries, transactions, parameter binding | Integration | `tests.rs` |
| **Elixir Ecto Adapter** | Storage ops, type conversion | Unit | `ecto_adapter_test.exs` |
| **Elixir SQL Generation** | DDL, indexes, constraints | Unit | `ecto_connection_test.exs` |
| **Full Ecto Integration** | Repos, schemas, queries, associations | Integration | `ecto_integration_test.exs` |
| **DBConnection Protocol** | Connection lifecycle, query execution | Unit | `ecto_libsql_test.exs` |
| **Migrations** | DDL execution, schema changes | Integration | `ecto_migration_test.exs` |
| **Error Handling** | Graceful degradation, VM stability | Integration | `error_handling_test.exs` |
| **Remote Operations** | Turso cloud, replica sync | Integration | `turso_remote_test.exs` |

**Total Test Count:**
- Rust: 19 tests
- Elixir: 118+ tests
- **Total: 137+ tests**

---

## Writing Tests

### When to Add Tests

- **New NIF functions**: Add integration test in `tests.rs` → `integration_tests` module
- **New utility functions**: Add unit test in appropriate module
- **Bug fixes**: Add regression test that would have caught the bug
- **New Ecto features**: Add test in relevant `test/*.exs` file
- **Error handling changes**: Add test in `error_handling_test.exs`

### Test Style Guidelines

#### Rust Tests

Tests in `tests.rs` **are allowed to use `.unwrap()`** because:
1. Tests are supposed to panic on failure
2. Keeps test code concise and readable
3. Test failures don't affect production

```rust
// ✅ This is fine in tests
#[tokio::test]
async fn test_my_feature() {
    let db_path = setup_test_db();
    let db = Builder::new_local(&db_path).build().await.unwrap();
    let conn = db.connect().unwrap();
    
    // Test code here
    
    cleanup_test_db(&db_path);
}
```

#### Elixir Tests

Follow ExUnit conventions:

```elixir
defmodule EctoLibSql.MyFeatureTest do
  use ExUnit.Case
  
  setup do
    # Setup code
    {:ok, state} = EctoLibSql.connect(database: ":memory:")
    
    on_exit(fn ->
      EctoLibSql.disconnect([], state)
    end)
    
    {:ok, state: state}
  end
  
  test "my feature works", %{state: state} do
    # Test code
    assert expected == actual
  end
end
```

### Test Naming

Use descriptive names that explain what's being tested:

```rust
// ✅ Good
#[test]
fn test_parameter_binding_with_floats() { ... }

// ❌ Bad
#[test]
fn test_floats() { ... }
```

```elixir
# ✅ Good
test "preloads user posts with correct order" do

# ❌ Bad
test "preload" do
```

### Test Data Cleanup

#### Rust Tests
- Use unique temporary database files: `test_{uuid}.db`
- Always call `cleanup_test_db()` at end of test
- Cleanup happens even on test failure (use Drop trait if needed)

#### Elixir Tests
- Use in-memory databases (`:memory:`) when possible
- Use `on_exit` callbacks to ensure cleanup
- Clean tables in `setup` blocks before each test

---

## Debugging Tests

### Debugging Rust Tests

```bash
# Run with output (see println! statements)
cargo test -- --nocapture

# Run specific test
cargo test test_parameter_binding_with_floats

# Show backtraces for panics
RUST_BACKTRACE=1 cargo test

# Show full backtraces
RUST_BACKTRACE=full cargo test

# Run tests in single thread (easier debugging)
cargo test -- --test-threads=1
```

### Debugging Elixir Tests

```bash
# Run with trace (shows each test as it runs)
mix test --trace

# Run specific test by line number
mix test test/ecto_integration_test.exs:123

# Debug with IEx (interactive debugging)
iex -S mix test --trace

# Run in single process (easier debugging)
mix test --trace --max-cases=1

# Add IO.inspect in test code
IO.inspect(state, label: "Current State")
IO.inspect(result, label: "Query Result")
```

### Common Issues

#### Issue: Test Database Not Cleaned Up

**Symptom**: Test fails with "table already exists"

**Solution**:
```elixir
setup do
  # Drop and recreate tables
  TestRepo.query!("DROP TABLE IF EXISTS users")
  TestRepo.query!("DROP TABLE IF EXISTS posts")
  
  # Or use on_exit
  on_exit(fn ->
    TestRepo.query!("DROP TABLE IF EXISTS users")
  end)
end
```

#### Issue: Rust Test Panics

**Symptom**: Test fails with cryptic error

**Solution**:
```bash
# Run with backtrace
RUST_BACKTRACE=1 cargo test test_name

# Check for unwrap() on production code (should use ? instead)
# Tests can use unwrap(), but production code cannot
```

#### Issue: Flaky Tests

**Symptom**: Test sometimes passes, sometimes fails

**Solution**:
- Check for race conditions
- Ensure proper cleanup between tests
- Use unique database names (UUID in path)
- Check for hardcoded IDs that might conflict

---

## CI/CD Integration

### GitHub Actions Workflow

The project uses comprehensive CI/CD in `.github/workflows/ci.yml`:

```yaml
name: CI
on: [push, pull_request]

jobs:
  rust-checks:
    runs-on: ${{ matrix.os }}
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest]
    steps:
      - uses: actions/checkout@v6
      - uses: dtolnay/rust-toolchain@stable
      - name: Check Rust formatting
        run: cargo fmt --check --manifest-path native/ecto_libsql/Cargo.toml
      - name: Run Clippy
        run: cargo clippy --manifest-path native/ecto_libsql/Cargo.toml
      - name: Run Rust tests
        run: cargo test --manifest-path native/ecto_libsql/Cargo.toml

  elixir-tests:
    runs-on: ${{ matrix.os }}
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest]
        elixir: ["1.17.0", "1.18.0"]
        otp: ["26.2", "27.0"]
    steps:
      - uses: actions/checkout@v6
      - uses: erlef/setup-beam@v1
        with:
          elixir-version: ${{ matrix.elixir }}
          otp-version: ${{ matrix.otp }}
      - name: Install dependencies
        run: mix deps.get
      - name: Check formatting
        run: mix format --check-formatted
      - name: Compile with warnings as errors
        run: mix compile --warnings-as-errors
      - name: Run tests
        run: mix test
```

**Benefits:**
- Tests on multiple OS (Ubuntu, macOS)
- Tests on multiple Elixir/OTP versions
- Caching for faster builds
- Parallel execution

---

## Best Practices

### For Contributors

1. **Always run tests before committing:**
   ```bash
   cd native/ecto_libsql && cargo test && cd ../.. && mix test
   ```

2. **Check formatting (required):**
   ```bash
   mix format --check-formatted
   ```

3. **Add tests for new features:**
   - Rust integration test if touching NIF code
   - Elixir unit test for Ecto adapter changes
   - Integration test for end-to-end features

4. **Test edge cases:**
   - NULL values
   - Empty strings
   - Large datasets
   - Transaction rollbacks
   - Connection failures
   - Invalid input

5. **Document test purpose:**
   ```rust
   /// Tests that float parameters are correctly bound and stored.
   /// This is a regression test for issue #123 where floats were
   /// incorrectly converted to integers.
   #[tokio::test]
   async fn test_parameter_binding_with_floats() { ... }
   ```

6. **Keep tests fast:**
   - Use in-memory databases when possible
   - Clean up resources promptly
   - Avoid unnecessary sleeps/waits

7. **Make tests deterministic:**
   - Don't rely on timing
   - Use unique IDs/names (UUIDs)
   - Clean up properly between tests

### Edge-Case Testing Guide

EctoLibSql includes comprehensive edge-case testing under concurrent load. These tests verify that the library handles unusual data correctly even when multiple processes are accessing the database simultaneously.

#### What Edge-Cases Are Tested

The test suite covers:

1. **NULL Values**: Ensure NULL is properly handled in concurrent inserts and transactions
2. **Empty Strings**: Verify empty strings aren't converted to NULL or corrupted
3. **Large Strings**: Test 1KB strings under concurrent load for truncation or corruption
4. **Special Characters**: Verify parameterised queries safely handle special characters (`!@#$%^&*()`)
5. **Recovery After Errors**: Confirm connection recovers after query errors without losing edge-case data
6. **Resource Cleanup**: Verify prepared statements with edge-case data are cleaned up correctly

#### Test Locations

- **Pool Load Tests**: `test/pool_load_test.exs`
  - `test "concurrent connections with edge-case data"` - 5 concurrent connections, 5 edge-case values each
  - `test "connection recovery with edge-case data"` - Error handling with NULL/empty/large strings
  - `test "prepared statements with edge-case data"` - Statement cleanup under concurrent load with edge cases

- **Transaction Isolation Tests**: `test/pool_load_test.exs`
  - `test "concurrent transactions with edge-case data maintain isolation"` - 4 transactions, edge-case values

#### Helper Functions

The test suite provides reusable helpers for edge-case testing:

```elixir
# Generate edge-case values for testing
defp generate_edge_case_values(task_num) do
  [
    "normal_value_#{task_num}",                       # Normal string
    nil,                                              # NULL value
    "",                                                # Empty string
    String.duplicate("x", 1000),                      # Large string (1KB)
    "special_chars_!@#$%^&*()_+-=[]{};"               # Special characters
  ]
end

# Insert edge-case value and return result
defp insert_edge_case_value(state, value) do
  EctoLibSql.handle_execute(
    "INSERT INTO test_data (value) VALUES (?)",
    [value],
    [],
    state
  )
end
```

#### When to Use Edge-Case Tests

Add edge-case tests when:
- Testing concurrent operations
- Adding support for new data types
- Changing query execution paths
- Modifying transaction handling
- Improving connection pooling

#### Expected Coverage

Edge-case tests should verify:
- Data integrity (no corruption, truncation, or loss)
- NULL value preservation
- String encoding correctness
- Parameter binding safety
- Error recovery without data loss
- Resource cleanup (statements, cursors, connections)

### Known Test Limitations

1. **Remote/Replica Mode Testing:**
   - Rust integration tests only cover local mode
   - Remote mode requires Turso credentials
   - Tested manually or in CI with secrets
   - Some tests tagged with `@tag :turso_remote` and skipped by default

2. **Concurrent Access:**
   - SQLite locking behaviour is hard to test
   - Tested in production-like scenarios
   - Some race conditions only appear under load

3. **Performance Testing:**
   - Not covered by unit tests
   - Use benchmarking tools separately
   - Consider adding `benches/` directory in future

4. **Memory Leak Detection:**
   - Difficult to test in short-running tests
   - Monitor in production
   - Consider adding long-running stress tests

### Contributing Tests Checklist

When contributing, ensure:

- [ ] All existing tests pass (`cargo test && mix test`)
- [ ] New features have test coverage
- [ ] Tests are documented with clear comments
- [ ] Test data is cleaned up properly
- [ ] Tests are deterministic (no random failures)
- [ ] Formatting is correct (`mix format --check-formatted`)
- [ ] No warnings in compilation
- [ ] Tests follow existing patterns and conventions

---

## Future Testing Improvements

Potential enhancements to the test suite:

- [ ] **Benchmarking suite** - Performance regression testing
- [ ] **Property-based testing** - Use Propcheck/StreamData for Elixir
- [ ] **Mutation testing** - Verify test quality with mutation testing
- [ ] **Integration tests for remote replica** - Full sync testing
- [ ] **Stress tests** - Connection pooling under load
- [ ] **Error recovery scenarios** - Test recovery from various failure modes
- [ ] **Test coverage reporting** - Add `tarpaulin` for Rust, ExCoveralls for Elixir
- [ ] **Separate test compilation** - Move integration tests to `tests/` directory
- [ ] **Performance benchmarks** - Add `benches/` directory with criterion.rs

---

## References

- [Rust Testing Guide](https://doc.rust-lang.org/book/ch11-00-testing.html)
- [Rust Project Structure](https://doc.rust-lang.org/book/ch07-00-managing-growing-projects-with-packages-crates-and-modules.html)
- [ExUnit Documentation](https://hexdocs.pm/ex_unit/ExUnit.html)
- [Ecto Testing Guide](https://hexdocs.pm/ecto/testing-with-ecto.html)
- [cargo test documentation](https://doc.rust-lang.org/cargo/commands/cargo-test.html)

---

**Last Updated**: 2024-11-30  
**Test Count**: 137+ tests (19 Rust + 118+ Elixir)  
**Status**: All tests passing ✅