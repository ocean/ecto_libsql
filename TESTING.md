# LibSqlEx Testing Guide

This document explains the comprehensive testing strategy for LibSqlEx, covering both the Rust NIF layer and the Elixir layer.

## Testing Architecture

LibSqlEx uses a **multi-layer testing approach**:

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

## Rust Tests

Location: `native/libsqlex/src/lib.rs` (in `#[cfg(test)]` module)

### Running Rust Tests

```bash
cd native/libsqlex
cargo test                    # Run all tests
cargo test -- --nocapture     # Show println! output
cargo test query_type         # Run specific test module
cargo test --lib              # Run only library tests
```

### Test Categories

#### 1. Unit Tests - Query Type Detection

**Module:** `tests::query_type_detection`

Tests the `detect_query_type()` function which parses SQL to determine query type.

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

#### 2. Integration Tests - Database Operations

**Module:** `tests::integration_tests`

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
    let db = Builder::new_local(&db_path).build().await.unwrap();
    let conn = db.connect().unwrap();

    conn.execute(
        "INSERT INTO products (id, price) VALUES (?1, ?2)",
        vec![Value::Integer(1), Value::Real(19.99)]
    ).await.unwrap();

    // Verify the float was stored correctly
}
```

**Key Test:** `test_parameter_binding_with_floats`
This test verifies the float parameter binding fix that was implemented earlier.

#### 3. Registry Tests

**Module:** `tests::registry_tests`

Tests the thread-safe registry infrastructure used for managing connections, transactions, statements, and cursors.

**Coverage:**
- UUID generation uniqueness
- Registry initialization and accessibility
- Thread safety (implicit through Mutex usage)

### Limitations of Rust NIF Testing

Some aspects are **difficult to test directly in Rust**:

1. **NIF Functions** - These require Rustler's `Env` and `Term` types which are only available when called from Elixir
2. **Registry Cleanup** - Full lifecycle testing requires integration with BEAM
3. **Mode Detection** - Requires Elixir atoms
4. **Error Propagation** - How errors surface to Elixir

**Solution:** These are tested at the **Elixir layer** instead.

## Elixir Tests

### Running Elixir Tests

```bash
mix test                                # Run all tests
mix test test/ecto_adapter_test.exs    # Run specific test file
mix test --trace                       # Show detailed output
mix test --cover                       # Generate coverage report
```

### Test Files

#### 1. `test/ecto_adapter_test.exs`

Tests the Ecto.Adapters.LibSqlEx adapter implementation.

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
  assert {:ok, false} == LibSqlEx.loaders(:boolean, :boolean) |> List.first() |> apply([0])
  assert {:ok, true} == LibSqlEx.loaders(:boolean, :boolean) |> List.first() |> apply([1])
end
```

#### 2. `test/ecto_connection_test.exs`

Tests Ecto.Adapters.LibSqlEx.Connection for SQL generation and DDL operations.

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
  TestRepo.insert(%Post{title: "Post 1", body: "Body 1", user_id: user.id})

  user_with_posts = User |> TestRepo.get(user.id) |> TestRepo.preload(:posts)
  assert length(user_with_posts.posts) == 2
end
```

## Test Coverage Summary

| Layer | What's Tested | Test Type | Location |
|-------|---------------|-----------|----------|
| **Rust Pure Functions** | Query type detection, UUID generation | Unit | `lib.rs` |
| **Rust Database Ops** | Connections, queries, transactions, parameter binding | Integration | `lib.rs` |
| **Elixir Ecto Adapter** | Storage ops, type conversion | Unit | `ecto_adapter_test.exs` |
| **Elixir SQL Generation** | DDL, indexes, constraints | Unit | `ecto_connection_test.exs` |
| **Full Ecto Integration** | Repos, schemas, queries, associations | Integration | `ecto_integration_test.exs` |

## Test Data Cleanup

### Rust Tests
- Use unique temporary database files: `test_{uuid}.db`
- Cleanup in `cleanup_test_db()` function
- Automatic cleanup even on test failure (Rust Drop trait)

### Elixir Tests
- Use separate test databases
- `setup` blocks clean tables before each test
- `on_exit` callbacks ensure cleanup

## Running All Tests

```bash
# Run both Rust and Elixir tests
cd native/libsqlex && cargo test && cd ../.. && mix test

# Or use a Makefile
make test
```

## Continuous Integration

Recommended CI setup:

```yaml
# .github/workflows/test.yml
name: Test
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: erlef/setup-beam@v1
        with:
          elixir-version: '1.17'
          otp-version: '26'
      - uses: actions-rs/toolchain@v1
        with:
          toolchain: stable

      - name: Install dependencies
        run: mix deps.get

      - name: Run Rust tests
        run: cd native/libsqlex && cargo test

      - name: Run Elixir tests
        run: mix test

      - name: Check formatting
        run: mix format --check-formatted
```

## Testing Best Practices

### For Contributors

1. **Run tests before committing:**
   ```bash
   cargo test && mix test
   ```

2. **Add tests for new features:**
   - Rust integration test if touching NIF code
   - Elixir unit test for Ecto adapter changes
   - Integration test for end-to-end features

3. **Test edge cases:**
   - Null values
   - Empty strings
   - Large datasets
   - Transaction rollbacks
   - Connection failures

4. **Use descriptive test names:**
   ```rust
   // Good
   #[test]
   fn test_parameter_binding_with_floats() { ... }

   // Bad
   #[test]
   fn test_floats() { ... }
   ```

### Known Test Limitations

1. **Remote/Replica Mode Testing:**
   - Rust integration tests only cover local mode
   - Remote mode requires Turso credentials
   - Tested manually or in CI with secrets

2. **Concurrent Access:**
   - SQLite locking behavior
   - Tested in production-like scenarios

3. **Performance Testing:**
   - Not covered by unit tests
   - Use benchmarking tools separately

## Debugging Failed Tests

### Rust Tests

```bash
# Run with output
cargo test -- --nocapture

# Run specific test
cargo test test_parameter_binding_with_floats

# Show backtraces
RUST_BACKTRACE=1 cargo test
```

### Elixir Tests

```bash
# Run with trace
mix test --trace

# Run specific test
mix test test/ecto_integration_test.exs:123

# Debug with IEx
iex -S mix test --trace
```

## Contributing Tests

When contributing, ensure:

✅ All existing tests pass
✅ New features have test coverage
✅ Tests are documented with comments
✅ Test data is cleaned up properly
✅ Tests are deterministic (no random failures)

Run the full test suite:
```bash
./scripts/test-all.sh  # If available
# or manually:
cd native/libsqlex && cargo test && cd ../.. && mix test
```

## Future Testing Improvements

- [ ] Add benchmarking suite for performance regression testing
- [ ] Add property-based testing (Propcheck for Elixir)
- [ ] Add mutation testing to verify test quality
- [ ] Add integration tests for remote replica mode
- [ ] Add stress tests for connection pooling
- [ ] Add tests for error recovery scenarios
