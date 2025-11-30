# EctoLibSql - AI Agent Guide (Internal Development)

> **Version**: 0.5.0  
> **Last Updated**: 2024-11-27  
> **Purpose**: Comprehensive guide for AI agents working **ON** the ecto_libsql codebase itself
>
> **⚠️ IMPORTANT**: This guide is for **developing and maintaining** the ecto_libsql library.  
> **📚 For using ecto_libsql in your applications**, see [AGENTS.md](AGENTS.md) instead.

## Table of Contents

- [Project Overview](#project-overview)
- [Architecture](#architecture)
- [Critical Rules](#critical-rules)
- [Code Structure](#code-structure)
- [Development Workflow](#development-workflow)
- [Error Handling Patterns](#error-handling-patterns)
- [Testing Strategy](#testing-strategy)
- [Common Tasks](#common-tasks)
- [Deployment & CI/CD](#deployment--cicd)
- [Troubleshooting](#troubleshooting)

---

---

## ℹ️ About This Guide

**CLAUDE.md** is the internal development guide for AI agents working on the ecto_libsql codebase itself. It covers:
- Internal architecture and code structure
- Rust NIF development patterns
- Error handling requirements
- Test organization
- CI/CD and release process

**If you're looking to USE ecto_libsql in your application**, you want [AGENTS.md](AGENTS.md) instead, which covers:
- How to integrate ecto_libsql into your Elixir/Phoenix app
- Ecto schemas, migrations, and queries
- Connection management and configuration
- Real-world usage examples
- Performance optimisation for applications

---

## Project Overview

### What is EctoLibSql?

EctoLibSql is a **production-ready Ecto adapter** for LibSQL and Turso databases, implemented as a Rust NIF (Native Implemented Function) for high performance. It provides full Ecto integration for Elixir applications using SQLite-compatible databases.

### Key Features

- **Full Ecto Support**: Schemas, migrations, queries, changesets, associations
- **Three Connection Modes**: Local SQLite, Remote Turso, Embedded Replica (local + cloud sync)
- **Advanced Features**: Vector similarity search, database encryption, prepared statements, batch operations
- **Production-Ready Error Handling**: Zero panic risk - all 146 `unwrap()` calls eliminated (v0.5.0)
- **High Performance**: Rust NIFs with async/await, connection pooling, cursor streaming

### Connection Modes

1. **Local Mode**: SQLite file on disk (`database: "local.db"`)
2. **Remote Mode**: Direct connection to Turso cloud (`uri` + `auth_token`)
3. **Embedded Replica Mode**: Local file with automatic cloud sync (`database` + `uri` + `auth_token` + `sync: true`)

---

## Architecture

### Layer Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Phoenix / Application Layer                            │
├─────────────────────────────────────────────────────────┤
│  Ecto.Adapters.LibSql (Elixir Ecto Adapter)           │
│  - Storage operations (create, drop, status)            │
│  - Type loaders/dumpers (boolean, datetime, etc.)       │
├─────────────────────────────────────────────────────────┤
│  Ecto.Adapters.LibSql.Connection (SQL Generation)      │
│  - Query compilation (SELECT, INSERT, UPDATE, DELETE)   │
│  - DDL operations (CREATE TABLE, ALTER, INDEX)          │
│  - Type mapping (Ecto types → SQLite types)             │
├─────────────────────────────────────────────────────────┤
│  EctoLibSql (DBConnection Protocol)                     │
│  - Connection lifecycle (connect, disconnect, ping)     │
│  - Transaction management (begin, commit, rollback)     │
│  - Query execution (execute, prepare, fetch)            │
│  - Cursor management (declare, fetch, deallocate)       │
├─────────────────────────────────────────────────────────┤
│  EctoLibSql.Native (Rust NIF Interface)                │
│  - Safe wrappers around Rust NIFs                       │
│  - Error handling and state management                  │
│  - Prepared statements, batches, metadata               │
├─────────────────────────────────────────────────────────┤
│  Rust NIF Implementation (native/ecto_libsql/src/)     │
│  - LibSQL client management (libsql-rs)                │
│  - Connection registry (Arc<Mutex<HashMap>>)            │
│  - Transaction registry                                 │
│  - Async runtime (Tokio)                                │
│  - Safe mutex locking (safe_lock helpers)               │
└─────────────────────────────────────────────────────────┘
```

### File Structure

```
ecto_libsql/
├── lib/
│   ├── ecto/adapters/
│   │   ├── libsql.ex                    # Main Ecto adapter
│   │   └── libsql/connection.ex         # SQL generation & DDL
│   ├── ecto_libsql/
│   │   ├── error.ex                     # Error exception struct
│   │   ├── native.ex                    # Rust NIF wrapper functions
│   │   ├── query.ex                     # Query protocol implementation
│   │   ├── result.ex                    # Result struct
│   │   └── state.ex                     # Connection state management
│   └── ecto_libsql.ex                   # DBConnection protocol
├── native/ecto_libsql/src/
│   ├── lib.rs                           # Main Rust NIF implementation (1,201 lines)
│   └── tests.rs                         # Rust tests (463 lines)
├── test/
│   ├── ecto_adapter_test.exs            # Adapter functionality tests
│   ├── ecto_connection_test.exs         # SQL generation tests
│   ├── ecto_integration_test.exs        # Full Ecto integration tests
│   ├── ecto_libsql_test.exs             # DBConnection tests
│   ├── ecto_migration_test.exs          # Migration tests
│   ├── error_handling_test.exs          # Error handling verification
│   └── turso_remote_test.exs            # Remote Turso tests
├── AGENTS.md                            # Comprehensive API documentation (2,600+ lines)
├── CLAUDE.md                            # This file (AI agent guide)
├── README.md                            # User-facing documentation
├── CHANGELOG.md                         # Version history
├── ECTO_MIGRATION_GUIDE.md             # Migration from PostgreSQL/MySQL
├── RUST_ERROR_HANDLING.md              # Rust error patterns quick reference
├── RESILIENCE_IMPROVEMENTS.md          # Error handling refactoring details
└── TESTING.md                          # Testing strategy and organization
```

---

## Critical Rules

### Before ANY Code Submission

```bash
# ALWAYS run this command before committing:
mix format --check-formatted

# If formatting errors, fix them:
mix format
```

**Why**: The project enforces strict formatting via CI. Unformatted code will fail the build.

### Rust Error Handling (MANDATORY)

**NEVER use `.unwrap()` in production Rust code**. All 146 unwrap calls were eliminated in v0.5.0 to prevent VM crashes.

#### ✅ ALWAYS DO:

```rust
// Use safe_lock helper for Mutex<T>
let conn_map = safe_lock(&CONNECTION_REGISTRY, "function_name context")?;

// Use safe_lock_arc helper for Arc<Mutex<T>>
let client_guard = safe_lock_arc(&client, "function_name context")?;

// Use ok_or_else for Option types
let conn = conn_map
    .get(conn_id)
    .ok_or_else(|| rustler::Error::Term(Box::new("Connection not found")))?;

// Use ? operator for error propagation
let result = some_operation().map_err(|e| rustler::Error::Term(Box::new(format!("Failed: {}", e))))?;
```

#### ❌ NEVER DO:

```rust
// WRONG - will panic and crash BEAM VM
let conn_map = CONNECTION_REGISTRY.lock().unwrap();
let conn = conn_map.get(conn_id).unwrap();
let result = some_operation().unwrap();
```

**See `RUST_ERROR_HANDLING.md` for complete patterns and examples.**

### Test Code Exception

Tests in `#[cfg(test)]` modules **MAY use `.unwrap()`** for simplicity:

```rust
#[tokio::test]
async fn test_something() {
    let db = Builder::new_local("test.db").build().await.unwrap(); // OK in tests
    // ...
}
```

---

## Code Structure

### Elixir Modules

#### `EctoLibSql` (lib/ecto_libsql.ex)
**Purpose**: DBConnection protocol implementation  
**Responsibilities**:
- Connection lifecycle (`connect/1`, `disconnect/2`, `ping/1`)
- Transaction management (`handle_begin/2`, `handle_commit/2`, `handle_rollback/2`)
- Query execution (`handle_execute/4`)
- Cursor operations (`handle_declare/4`, `handle_fetch/4`, `handle_deallocate/4`)

**Key Functions**:
```elixir
def connect(opts)                              # Opens connection (local/remote/replica)
def handle_execute(query, args, opts, state)   # Executes SQL with parameters
def handle_begin(opts, state)                  # Starts transaction
def handle_commit(opts, state)                 # Commits transaction
def handle_declare(query, params, opts, state) # Creates cursor for streaming
```

#### `EctoLibSql.Native` (lib/ecto_libsql/native.ex)
**Purpose**: Safe Elixir wrappers around Rust NIFs  
**Responsibilities**:
- State management with `EctoLibSql.State` struct
- Error handling and type conversions
- Prepared statements (`prepare/2`, `query_stmt/3`, `execute_stmt/4`)
- Batch operations (`batch/2`, `batch_transactional/2`)
- Metadata access (`get_last_insert_rowid/1`, `get_changes/1`)
- Vector operations (`vector/1`, `vector_type/2`, `vector_distance_cos/2`)

**Key Functions**:
```elixir
def query(state, query, args)                  # Execute query with state
def begin(state, opts \\ [])                   # Begin transaction with behavior
def commit(state)                              # Commit with optional sync
def rollback(state)                            # Rollback transaction
def sync(state)                                # Manual replica sync
def prepare(state, sql)                        # Prepare statement (returns stmt_id)
def batch(state, statements)                   # Non-transactional batch
def batch_transactional(state, statements)     # Transactional batch
```

#### `Ecto.Adapters.LibSql` (lib/ecto/adapters/libsql.ex)
**Purpose**: Main Ecto adapter  
**Responsibilities**:
- Storage operations (`storage_up/1`, `storage_down/1`, `storage_status/1`)
- Type loaders/dumpers for Ecto ↔ SQLite conversion
- Migration support (`supports_ddl_transaction?/0`, `lock_for_migrations/3`)
- Structure operations (`structure_dump/2`, `structure_load/2`)

**Type Mappings**:
- `:boolean` → 0/1 integers
- `:binary_id` → TEXT (UUID)
- `:utc_datetime`, `:naive_datetime` → ISO8601 strings
- `:decimal` → TEXT (Decimal.to_string)
- `:binary` → BLOB

#### `Ecto.Adapters.LibSql.Connection` (lib/ecto/adapters/libsql/connection.ex)
**Purpose**: SQL generation and DDL operations  
**Responsibilities**:
- Query compilation (`all/1`, `update_all/1`, `delete_all/1`)
- DDL generation (`execute_ddl/1`)
- Expression building (`expr/3`, `where/2`, `join/2`)
- Constraint conversion (`to_constraints/2`)

**DDL Support**:
- `CREATE TABLE`, `DROP TABLE`, `ALTER TABLE`
- `CREATE INDEX`, `DROP INDEX` (including UNIQUE and partial indexes)
- `RENAME TABLE`, `RENAME COLUMN`
- Foreign keys, constraints, composite primary keys

#### `EctoLibSql.State` (lib/ecto_libsql/state.ex)
**Purpose**: Connection state tracking  
**Fields**:
- `:conn_id` - Unique connection identifier (UUID)
- `:trx_id` - Active transaction ID (nil if no transaction)
- `:mode` - Connection mode (`:local`, `:remote`, `:remote_replica`)
- `:sync` - Sync setting (`:enable_sync` or `:disable_sync`)

**Mode Detection**:
```elixir
# Local mode
detect_mode(database: "local.db") → :local

# Remote mode
detect_mode(uri: "libsql://...", auth_token: "...") → :remote

# Replica mode
detect_mode(database: "local.db", uri: "libsql://...", auth_token: "...", sync: true) → :remote_replica
```

### Rust Code Structure

#### `native/ecto_libsql/src/lib.rs` (1,201 lines)

**Key Data Structures**:
```rust
// Connection resource
pub struct LibSQLConn {
    pub db: libsql::Database,
    pub client: Arc<Mutex<libsql::Connection>>,
}

// Cursor data
pub struct CursorData {
    pub columns: Vec<String>,
    pub rows: Vec<Vec<Value>>,
    pub position: usize,
}

// Global registries (thread-safe)
static ref TXN_REGISTRY: Mutex<HashMap<String, Transaction>>
static ref STMT_REGISTRY: Mutex<HashMap<String, (String, String)>>
static ref CURSOR_REGISTRY: Mutex<HashMap<String, CursorData>>
static ref CONNECTION_REGISTRY: Mutex<HashMap<String, Arc<Mutex<LibSQLConn>>>>
```

**Helper Functions**:
```rust
// Safe mutex locking (prevents panics)
fn safe_lock<'a, T>(mutex: &'a Mutex<T>, context: &str) -> Result<MutexGuard<'a, T>, rustler::Error>
fn safe_lock_arc<'a, T>(arc_mutex: &'a Arc<Mutex<T>>, context: &str) -> Result<MutexGuard<'a, T>, rustler::Error>

// Sync with timeout
async fn sync_with_timeout(client: &Arc<Mutex<LibSQLConn>>, timeout_secs: u64) -> Result<(), String>
```

**NIF Functions** (all return `NifResult<T>` for safety):
- `connect(opts, mode)` - Opens connection
- `ping(conn_id)` - Health check
- `query_args(conn_id, mode, sync, query, args)` - Execute query
- `begin_transaction(conn_id)` - Start transaction
- `begin_transaction_with_behavior(conn_id, behavior)` - Start with isolation level
- `execute_with_transaction(trx_id, query, args)` - Execute in transaction
- `commit_or_rollback_transaction(trx_id, conn_id, mode, sync, param)` - Finish transaction
- `prepare_statement(conn_id, sql)` - Prepare statement
- `query_prepared(conn_id, stmt_id, mode, sync, args)` - Execute prepared (returns rows)
- `execute_prepared(conn_id, stmt_id, mode, sync, sql_hint, args)` - Execute prepared (returns count)
- `declare_cursor(conn_id, sql, args)` - Create cursor
- `fetch_cursor(cursor_id, max_rows)` - Fetch cursor batch
- `close(id, opt)` - Close connection/transaction/statement/cursor

#### `native/ecto_libsql/src/tests.rs` (463 lines)

**Test Modules**:
1. **`query_type_detection`**: Tests SQL query type detection (SELECT, INSERT, etc.)
2. **`integration_tests`**: Real database operations with temporary SQLite files
3. **`registry_tests`**: UUID generation and registry initialization

**Helper Functions**:
```rust
fn setup_test_db() -> String                   // Creates temp DB with UUID name
fn cleanup_test_db(path: &str)                 // Removes test DB files
```

---

## Development Workflow

### Setting Up Development Environment

```bash
# Clone and setup
git clone <repo-url>
cd ecto_libsql

# Install Elixir dependencies
mix deps.get

# Compile (includes Rust NIF compilation via rustler)
mix compile

# Run tests
mix test

# Run Rust tests
cd native/ecto_libsql && cargo test
```

### Typical Development Cycle

1. **Make changes** to Elixir or Rust code
2. **Format code**: `mix format` (Elixir), `cargo fmt` (Rust)
3. **Run tests**: `mix test` and `cargo test`
4. **Check formatting**: `mix format --check-formatted`
5. **Static analysis** (optional): `cd native/ecto_libsql && cargo clippy`
6. **Commit changes** with descriptive message

### Adding New Features

#### Adding a New NIF Function

1. **Define Rust NIF** in `native/ecto_libsql/src/lib.rs`:
```rust
#[rustler::nif(schedule = "DirtyIo")]
pub fn my_new_function(conn_id: &str, param: &str) -> NifResult<String> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "my_new_function")?;
    let client = conn_map
        .get(conn_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Connection not found")))?;
    
    // Implementation here
    
    Ok("result".to_string())
}
```

2. **Export in Rustler module** (in `rustler::init!` macro):
```rust
rustler::init!(
    "Elixir.EctoLibSql.Native",
    [
        // ... existing functions ...
        my_new_function,
    ]
)
```

3. **Add Elixir wrapper** in `lib/ecto_libsql/native.ex`:
```elixir
def my_new_function(_conn, _param), do: :erlang.nif_error(:nif_not_loaded)

# Add safe wrapper
def my_new_function_safe(%EctoLibSql.State{conn_id: conn_id} = _state, param) do
  case my_new_function(conn_id, param) do
    {:ok, result} -> {:ok, result}
    {:error, reason} -> {:error, reason}
  end
end
```

4. **Add tests**:
   - Rust test in `native/ecto_libsql/src/tests.rs`
   - Elixir test in appropriate test file

5. **Document** in `AGENTS.md` and update `CHANGELOG.md`

#### Adding a New Ecto Feature

1. **Update Connection module** (`lib/ecto/adapters/libsql/connection.ex`) if SQL generation needed
2. **Update Adapter module** (`lib/ecto/adapters/libsql.ex`) if storage/type handling needed
3. **Add tests** in `test/ecto_*_test.exs` files
4. **Update documentation** in README and AGENTS.md

### Working with Migrations

```bash
# Generate migration
mix ecto.gen.migration create_users

# Run migrations
mix ecto.migrate

# Rollback
mix ecto.rollback

# Check migration status
mix ecto.migrations
```

**Note**: SQLite has limited ALTER TABLE support. For column type changes or drops, you must recreate the table (see `ECTO_MIGRATION_GUIDE.md`).

---

## Error Handling Patterns

### Rust Error Handling (Critical!)

#### Pattern 1: Lock a Registry
```rust
// ✅ CORRECT
let conn_map = safe_lock(&CONNECTION_REGISTRY, "function_name conn_map")?;

// ❌ WRONG - will panic!
let conn_map = CONNECTION_REGISTRY.lock().unwrap();
```

#### Pattern 2: Lock Nested Arc<Mutex<T>>
```rust
// ✅ CORRECT
let client_guard = safe_lock_arc(&client, "function_name client")?;
let conn_guard = safe_lock_arc(&client_guard.client, "function_name conn")?;

// ❌ WRONG
let result = client.lock().unwrap().client.lock().unwrap();
```

#### Pattern 3: Handle Option Types
```rust
// ✅ CORRECT
let conn = conn_map
    .get(conn_id)
    .ok_or_else(|| rustler::Error::Term(Box::new("Connection not found")))?;

// ❌ WRONG
let conn = conn_map.get(conn_id).unwrap();
```

#### Pattern 4: Async Error Conversion
```rust
// ✅ CORRECT - async blocks use String errors
TOKIO_RUNTIME.block_on(async {
    let guard = safe_lock_arc(&client, "context")
        .map_err(|e| format!("{:?}", e))?;
    guard
        .query(sql, params)
        .await
        .map_err(|e| format!("{:?}", e))
})
```

#### Pattern 5: Drop Locks Before Async
```rust
// ✅ CORRECT
let conn_map = safe_lock(&CONNECTION_REGISTRY, "function")?;
let client = conn_map.get(conn_id).cloned()
    .ok_or_else(|| rustler::Error::Term(Box::new("Connection not found")))?;
drop(conn_map); // Release lock!

TOKIO_RUNTIME.block_on(async {
    // Async work here
})
```

### Elixir Error Handling

#### Pattern 1: Match on Results
```elixir
case EctoLibSql.Native.query(state, sql, params) do
  {:ok, query, result, new_state} -> 
    # Success path
  {:error, reason} -> 
    # Error path
end
```

#### Pattern 2: With Clause
```elixir
with {:ok, state} <- EctoLibSql.connect(opts),
     {:ok, _query, result, state} <- EctoLibSql.handle_execute(sql, [], [], state) do
  # Success
else
  {:error, reason} -> # Handle error
end
```

#### Pattern 3: Raise on Ecto Operations
```elixir
# Ecto operations typically raise on error
user = Repo.get!(User, id)  # Raises if not found
{:ok, user} = Repo.insert(changeset)  # Returns tuple
```

---

## Testing Strategy

### Test Organisation

```
test/
├── ecto_adapter_test.exs           # Storage, type loaders/dumpers
├── ecto_connection_test.exs        # SQL generation, DDL
├── ecto_integration_test.exs       # Full Ecto workflows (CRUD, associations, etc.)
├── ecto_libsql_test.exs            # DBConnection protocol
├── ecto_migration_test.exs         # Migration operations
├── error_handling_test.exs         # Error handling verification
└── turso_remote_test.exs           # Remote Turso database tests (optional)

native/ecto_libsql/src/
├── lib.rs                          # Production code (no unwrap!)
└── tests.rs                        # Test code (can use unwrap)
```

### Running Tests

```bash
# All Elixir tests
mix test

# Specific test file
mix test test/ecto_integration_test.exs

# Specific test line
mix test test/ecto_integration_test.exs:42

# With trace
mix test --trace

# Exclude Turso remote tests (require credentials)
mix test --exclude turso_remote

# All Rust tests
cd native/ecto_libsql && cargo test

# Specific Rust test
cargo test test_parameter_binding_with_floats

# With output
cargo test -- --nocapture

# Both Elixir and Rust
cd native/ecto_libsql && cargo test && cd ../.. && mix test
```

### Writing Tests

#### Elixir Integration Test Example
```elixir
defmodule EctoLibSql.MyFeatureTest do
  use ExUnit.Case
  
  setup do
    {:ok, state} = EctoLibSql.connect(database: "test_#{:erlang.unique_integer()}.db")
    
    # Setup schema
    EctoLibSql.handle_execute("CREATE TABLE users (id INTEGER, name TEXT)", [], [], state)
    
    on_exit(fn ->
      EctoLibSql.disconnect([], state)
    end)
    
    {:ok, state: state}
  end
  
  test "my feature works", %{state: state} do
    {:ok, _query, result, _state} = 
      EctoLibSql.handle_execute("INSERT INTO users VALUES (1, 'Alice')", [], [], state)
    
    assert result.num_rows == 1
  end
end
```

#### Rust Integration Test Example
```rust
#[tokio::test]
async fn test_my_feature() {
    let db_path = setup_test_db();
    let db = Builder::new_local(&db_path).build().await.unwrap();
    let conn = db.connect().unwrap();
    
    conn.execute("CREATE TABLE test (id INTEGER)", vec![]).await.unwrap();
    
    // Test code here
    
    cleanup_test_db(&db_path);
}
```

### Test Coverage Areas

**Must have tests for**:
- ✅ Happy path (successful operations)
- ✅ Error cases (invalid IDs, missing resources, constraint violations)
- ✅ Edge cases (NULL values, empty strings, large datasets)
- ✅ Transaction rollback scenarios
- ✅ Type conversions (Elixir ↔ SQLite)
- ✅ Concurrent operations (if applicable)

---

## Common Tasks

### Task 1: Add Support for a New SQLite Function

**Example**: Adding support for `RANDOM()`

1. **No Rust changes needed** if function is native to SQLite
2. **Update Connection module** if special handling needed:

```elixir
# In lib/ecto/adapters/libsql/connection.ex
defp expr({:random, _, []}, _sources, _query) do
  "RANDOM()"
end
```

3. **Add test**:
```elixir
test "generates RANDOM() function" do
  query = from u in User, select: fragment("RANDOM()")
  assert SQL.all(query) =~ "RANDOM()"
end
```

### Task 2: Fix a Type Conversion Issue

**Example**: Boolean values not converting properly

1. **Check loaders** in `lib/ecto/adapters/libsql.ex`:
```elixir
def loaders(:boolean, type), do: [&bool_decode/1, type]

defp bool_decode(0), do: {:ok, false}
defp bool_decode(1), do: {:ok, true}
defp bool_decode(x), do: {:ok, x}  # Fallback
```

2. **Check dumpers**:
```elixir
def dumpers(:boolean, type), do: [type, &bool_encode/1]

defp bool_encode(false), do: {:ok, 0}
defp bool_encode(true), do: {:ok, 1}
```

3. **Add test**:
```elixir
test "boolean conversion" do
  user = %User{active: true}
  {:ok, saved} = Repo.insert(user)
  assert saved.active == true
end
```

### Task 3: Improve Error Messages

**Example**: Make "Connection not found" more descriptive

1. **Update Rust error**:
```rust
// Before
.ok_or_else(|| rustler::Error::Term(Box::new("Connection not found")))?

// After
.ok_or_else(|| {
    rustler::Error::Term(Box::new(format!(
        "Connection '{}' not found. It may have been closed or never existed.",
        conn_id
    )))
})?
```

2. **Add test** to verify error message:
```elixir
test "descriptive error for invalid connection" do
  {:error, msg} = EctoLibSql.Native.ping("invalid-id")
  assert msg =~ "not found"
  assert msg =~ "closed or never existed"
end
```

### Task 4: Add a New DDL Operation

**Example**: Support `CREATE INDEX IF NOT EXISTS`

1. **Update Connection module**:
```elixir
def execute_ddl({:create_if_not_exists, %Index{} = index}) do
  [
    "CREATE",
    if(index.unique, do: " UNIQUE", else: ""),
    " INDEX IF NOT EXISTS ",
    quote_name(index.name),
    " ON ",
    quote_table(index.prefix, index.table),
    # ... rest of implementation
  ] |> IO.iodata_to_binary()
end
```

2. **Add test**:
```elixir
test "CREATE INDEX IF NOT EXISTS" do
  index = %Index{name: :idx_email, table: :users, columns: [:email]}
  [sql] = Connection.execute_ddl({:create_if_not_exists, index})
  assert sql =~ "CREATE INDEX IF NOT EXISTS"
end
```

### Task 5: Debug a Failing Test

1. **Run with trace**: `mix test test/file.exs:123 --trace`
2. **Check logs**: Tests configure logger to `:info` level
3. **Add debug output**:
```elixir
IO.inspect(state, label: "State")
IO.inspect(result, label: "Result")
```
4. **Check Rust output**: `cd native/ecto_libsql && cargo test -- --nocapture`
5. **Verify NIF loading**: `File.exists?("priv/native/ecto_libsql.so")`

---

## Deployment & CI/CD

### GitHub Actions Workflow

The project has comprehensive CI/CD in `.github/workflows/ci.yml`:

**Jobs**:
1. **rust-checks**: Format, clippy, tests (Ubuntu + macOS)
2. **elixir-tests-latest**: Latest Elixir/OTP (1.18/27)
3. **elixir-tests-compatibility**: Older versions (1.17/26)
4. **integration-test**: Full test suite
5. **turso-remote-tests**: Turso cloud tests (optional, requires secrets)

**Matrix Testing**:
- OS: Ubuntu Latest, macOS Latest
- Elixir: 1.17, 1.18
- OTP: 26, 27
- Rust: Stable

**Cache Strategy**:
- Cargo dependencies cached by Cargo.toml hash
- Mix dependencies cached by mix.exs hash
- Significantly speeds up CI runs

### Pre-Commit Checklist

```bash
# 1. Format code
mix format
cd native/ecto_libsql && cargo fmt

# 2. Run tests
mix test
cd native/ecto_libsql && cargo test

# 3. Check formatting (will fail in CI if wrong)
mix format --check-formatted

# 4. Static analysis (optional but recommended)
cd native/ecto_libsql
cargo clippy
cargo check

# 5. Commit
git add .
git commit -m "feat: descriptive message"
```

### Release Process

1. **Update version** in `mix.exs`
2. **Update CHANGELOG.md** with changes
3. **Update README.md** if needed
4. **Run full test suite**: `mix test && cd native/ecto_libsql && cargo test`
5. **Tag release**: `git tag v0.x.x`
6. **Push**: `git push && git push --tags`
7. **Publish to Hex**: `mix hex.publish`

### Hex Package Files

From `mix.exs` package configuration:
```elixir
files: ~w(lib priv .formatter.exs mix.exs README* LICENSE* CHANGELOG* AGENT* native)
```

**Included**:
- `lib/` - All Elixir source
- `priv/` - Compiled NIF libraries
- `native/` - Rust source (compiled by rustler)
- Documentation files

**Excluded**:
- `test/`
- `examples/`
- Build artifacts (`_build/`, `target/`)

---

## Troubleshooting

### Issue: NIF Not Loaded

**Symptoms**:
```elixir
** (ErlangError) Erlang error: :nif_not_loaded
```

**Causes**:
1. NIF library not compiled
2. NIF library in wrong location
3. Rustler not installed

**Solutions**:
```bash
# 1. Clean and recompile
mix clean
mix deps.clean rustler --build
mix compile

# 2. Verify NIF exists
ls -la priv/native/ecto_libsql.so  # Linux
ls -la priv/native/libecto_libsql.dylib  # macOS

# 3. Check Rust toolchain
rustc --version
cargo --version

# 4. Manually compile NIF
cd native/ecto_libsql
cargo build --release
```

### Issue: Database Locked

**Symptoms**:
```
** (EctoLibSql.Error) database is locked
```

**Causes**:
- Another process has exclusive lock
- Long-running transaction
- Connection not properly closed

**Solutions**:
```elixir
# 1. Use transactions properly
Repo.transaction(fn ->
  # All operations here
end, timeout: 15_000)

# 2. Ensure connections are closed
{:ok, state} = EctoLibSql.connect(opts)
try do
  # Operations
after
  EctoLibSql.disconnect([], state)
end

# 3. Use immediate transactions for writes
EctoLibSql.Native.begin(state, behavior: :immediate)
```

### Issue: Type Conversion Errors

**Symptoms**:
```
** (Ecto.ChangeError) value `"string"` for `User.age` does not match type :integer
```

**Causes**:
- Incorrect type in schema
- Data stored in wrong format
- Missing type loader/dumper

**Solutions**:
```elixir
# 1. Verify schema types match database
schema "users" do
  field :age, :integer  # Must match actual SQLite column
end

# 2. Check custom types have loaders/dumpers
def loaders(:my_type, type), do: [&my_decode/1, type]
def dumpers(:my_type, type), do: [type, &my_encode/1]

# 3. Use cast in changesets
def changeset(user, attrs) do
  user
  |> cast(attrs, [:age])  # Will attempt type conversion
  |> validate_required([:age])
end
```

### Issue: Migration Fails

**Symptoms**:
```
** (Ecto.MigrationError) cannot alter column type
```

**Causes**:
- SQLite doesn't support ALTER COLUMN
- SQLite < 3.35.0 doesn't support DROP COLUMN

**Solutions**:

See `ECTO_MIGRATION_GUIDE.md` for table recreation pattern:

```elixir
def up do
  # Create new table with desired schema
  create table(:users_new) do
    add :id, :integer, primary_key: true
    add :name, :string
    add :age, :string  # Changed from :integer
    timestamps()
  end

  # Copy data with transformation
  execute """
  INSERT INTO users_new (id, name, age, inserted_at, updated_at)
  SELECT id, name, CAST(age AS TEXT), inserted_at, updated_at
  FROM users
  """

  # Swap tables
  drop table(:users)
  rename table(:users_new), to: table(:users)

  # Recreate indexes
  create unique_index(:users, [:email])
end
```

### Issue: Turso Connection Fails

**Symptoms**:
```
** (EctoLibSql.Error) connection failed: authentication error
```

**Causes**:
- Invalid auth token
- Incorrect URI
- Network issues

**Solutions**:
```bash
# 1. Verify credentials
turso db show <database-name>
turso db tokens create <database-name>

# 2. Test connection directly
export TURSO_URL="libsql://your-db.turso.io"
export TURSO_AUTH_TOKEN="your-token"

# 3. Check in config
config :my_app, MyApp.Repo,
  adapter: Ecto.Adapters.LibSql,
  uri: System.get_env("TURSO_URL"),  # Must include libsql:// prefix
  auth_token: System.get_env("TURSO_AUTH_TOKEN")

# 4. Use replica mode for better error handling
config :my_app, MyApp.Repo,
  database: "replica.db",  # Local fallback
  uri: System.get_env("TURSO_URL"),
  auth_token: System.get_env("TURSO_AUTH_TOKEN"),
  sync: true
```

### Issue: Test Failures After Refactoring

**Symptoms**:
```
1) test my feature (MyTest)
   Assertion with == failed
```

**Debug Process**:
```bash
# 1. Run single test with trace
mix test test/my_test.exs:42 --trace

# 2. Check if database state is clean
# Each test should setup/teardown properly

# 3. Verify NIF recompiled
mix clean
mix compile

# 4. Check for race conditions
# Run test multiple times
for i in {1..10}; do mix test test/my_test.exs:42; done

# 5. Check Rust tests still pass
cd native/ecto_libsql && cargo test
```

### Issue: Memory Leak Suspected

**Symptoms**:
- Growing memory usage over time
- Cursor/connection not released

**Debug**:
```elixir
# 1. Check connection registry size
# (Add debug function in development)

# 2. Ensure cursors are deallocated
DBConnection.stream(conn, query, [])
|> Stream.take(100)
|> Enum.to_list()
# Cursor automatically deallocated when stream ends

# 3. Close connections properly
{:ok, conn} = DBConnection.start_link(EctoLibSql, opts)
try do
  # Work
after
  DBConnection.close(conn)
end

# 4. Use connection pooling
config :my_app, MyApp.Repo,
  pool_size: 10,  # Limit concurrent connections
  queue_target: 50,
  queue_interval: 1000
```

### Issue: Vector Search Not Working

**Symptoms**:
```
** (EctoLibSql.Error) no such function: vector
```

**Causes**:
- Using wrong LibSQL version
- Vector extension not enabled

**Solutions**:
```elixir
# 1. Verify LibSQL version
# Check native/ecto_libsql/Cargo.toml
libsql = { version = "0.9.24", features = ["encryption"] }

# 2. Use correct vector syntax
vector_type = EctoLibSql.Native.vector_type(128, :f32)
sql = "CREATE TABLE docs (id INTEGER, embedding #{vector_type})"

# 3. Insert vectors correctly
vec = EctoLibSql.Native.vector([1.0, 2.0, 3.0])
sql = "INSERT INTO docs VALUES (?, vector(?))"
params = [1, vec]

# 4. Query with vector distance
query_vec = [1.5, 2.1, 2.9]
distance = EctoLibSql.Native.vector_distance_cos("embedding", query_vec)
sql = "SELECT id FROM docs ORDER BY #{distance} LIMIT 10"
```

---

## Quick Reference

### Connection Options

| Option | Type | Description | Required For |
|--------|------|-------------|--------------|
| `:database` | string | Local SQLite file path | Local, Replica |
| `:uri` | string | Turso database URI | Remote, Replica |
| `:auth_token` | string | Turso auth token | Remote, Replica |
| `:sync` | boolean | Auto-sync for replicas | Replica |
| `:encryption_key` | string | AES-256 encryption key (32+ chars) | Optional |
| `:pool_size` | integer | Connection pool size | Optional |

### Transaction Behaviours

| Behavior | Description | Use Case |
|----------|-------------|----------|
| `:deferred` (default) | Lock acquired on first write | Most reads |
| `:immediate` | Write lock acquired immediately | Write-heavy transactions |
| `:exclusive` | Exclusive lock, blocks all access | Critical operations |
| `:read_only` | Read-only transaction | Read-only queries |

### Ecto Type Mappings

| Ecto Type | SQLite Type | Notes |
|-----------|-------------|-------|
| `:id`, `:integer` | INTEGER | Auto-increment for primary keys |
| `:binary_id` | TEXT | Stored as UUID string |
| `:string` | TEXT | Variable length |
| `:text` | TEXT | Long text |
| `:boolean` | INTEGER | 0=false, 1=true |
| `:decimal` | TEXT | Stored as Decimal string |
| `:float` | REAL | Double precision |
| `:binary` | BLOB | Binary data |
| `:map`, `{:map, _}` | TEXT | Stored as JSON |
| `:date` | TEXT | ISO8601 format |
| `:time` | TEXT | ISO8601 format |
| `:naive_datetime` | TEXT | ISO8601 format |
| `:utc_datetime` | TEXT | ISO8601 format |

### Important Commands

```bash
# Format check (required before commit)
mix format --check-formatted

# Format code
mix format

# Run all tests
mix test

# Run specific test
mix test test/file.exs:42

# Run with trace
mix test --trace

# Exclude Turso tests
mix test --exclude turso_remote

# Rust tests
cd native/ecto_libsql && cargo test

# Rust format
cd native/ecto_libsql && cargo fmt

# Rust lint
cd native/ecto_libsql && cargo clippy

# Clean rebuild
mix clean && mix compile

# Generate docs
mix docs
```

---

## Resources & Further Reading

### Documentation Files (In This Repo)

- **AGENTS.md** (2,600+ lines) - Complete API reference with examples
- **README.md** - User-facing documentation and quick start
- **CHANGELOG.md** - Version history and migration notes
- **ECTO_MIGRATION_GUIDE.md** - Migrating from PostgreSQL/MySQL
- **RUST_ERROR_HANDLING.md** - Rust error patterns quick reference
- **RESILIENCE_IMPROVEMENTS.md** - Error handling refactoring details
- **TESTING.md** - Testing strategy, organization, and best practices

### External Resources

**LibSQL & Turso**:
- [LibSQL Documentation](https://github.com/tursodatabase/libsql)
- [Turso SQLite compatibility](https://github.com/tursodatabase/turso/blob/main/COMPAT.md)
- [Turso Rust bindings docs](https://github.com/tursodatabase/turso/tree/main/bindings/rust)
- [Turso Documentation](https://docs.turso.tech/)
- [Turso CLI](https://docs.turso.tech/reference/turso-cli)

**Ecto**:
- [Ecto Documentation](https://hexdocs.pm/ecto/)
- [Ecto.Query](https://hexdocs.pm/ecto/Ecto.Query.html)
- [Ecto.Migration](https://hexdocs.pm/ecto_sql/Ecto.Migration.html)

**Rust & NIFs**:
- [Rustler Documentation](https://github.com/rusterlium/rustler)
- [Rust Book](https://doc.rust-lang.org/book/)
- [Async Rust](https://rust-lang.github.io/async-book/)

**SQLite**:
- [SQLite Documentation](https://www.sqlite.org/docs.html)
- [SQLite ALTER TABLE Limitations](https://www.sqlite.org/lang_altertable.html)

---

## Version History

### v0.5.0 (2024-11-27) - Current
- **Zero panic Rust NIF** - All 146 `unwrap()` calls eliminated
- **Production-ready error handling** - All errors return tuples to Elixir
- **VM stability** - NIF errors no longer crash BEAM VM
- **Comprehensive error tests** - 21 tests verifying graceful error handling

### v0.4.0 (2024-11-19)
- **Renamed from LibSqlEx to EctoLibSql**
- All modules, packages, and documentation updated

### v0.3.0 (2024-11-17)
- **Full Ecto adapter implementation**
- Phoenix integration support
- Migration support with DDL operations
- Type loaders/dumpers
- Comprehensive test suite

### v0.2.0
- DBConnection protocol implementation
- Transaction support with isolation levels
- Prepared statements and batch operations
- Cursor support for streaming
- Vector search and encryption

---

## Contributing Guidelines

### For AI Agents

When working on this codebase:

1. **ALWAYS format before committing**: `mix format --check-formatted`
2. **NEVER use `.unwrap()` in Rust production code** - use `safe_lock` helpers
3. **Add tests** for all new features
4. **Update documentation** - at minimum CHANGELOG.md and relevant .md files
5. **Run both Rust and Elixir tests** before considering work complete
6. **Follow existing patterns** - grep for similar code first
7. **Include error handling** - every NIF should return proper error tuples
8. **Document edge cases** - especially SQLite limitations

### Code Review Checklist

Before submitting changes:

- [ ] `mix format --check-formatted` passes
- [ ] `mix test` passes (all 118+ tests)
- [ ] `cargo test` passes (all 19+ tests)
- [ ] No `.unwrap()` in Rust production code
- [ ] New features have tests
- [ ] Documentation updated (CHANGELOG.md minimum)
- [ ] Error handling is comprehensive
- [ ] No warnings in compilation
- [ ] CI will pass (format, tests, clippy)

### Getting Help

1. **Check documentation first**: AGENTS.md has extensive examples
2. **Search similar code**: Use grep to find existing patterns
3. **Check error handling guide**: RUST_ERROR_HANDLING.md has common patterns
4. **Review test files**: See how features are tested
5. **Check GitHub issues**: May already be documented

---

## Summary

EctoLibSql is a mature, production-ready Ecto adapter for LibSQL/Turso with:

- ✅ **Full Ecto support** - schemas, migrations, queries, associations
- ✅ **Three connection modes** - local, remote, embedded replica
- ✅ **Advanced features** - vector search, encryption, streaming
- ✅ **Production-ready** - zero panic risk, comprehensive error handling
- ✅ **Well-tested** - 137+ tests (118 Elixir + 19 Rust)
- ✅ **Well-documented** - 5,000+ lines of documentation
- ✅ **CI/CD ready** - GitHub Actions with matrix testing

**Key Principle**: Safety first. All Rust code uses proper error handling to protect the BEAM VM. All errors are returned as tuples that can be supervised and handled gracefully.

**For AI Agents**: Follow the critical rules, especially formatting and Rust error handling. Use existing documentation and patterns. Test thoroughly. You're working on production code that powers real applications.

---

**Last Updated**: 2024-11-27  
**Maintained By**: ocean  
**License**: Apache 2.0  
**Repository**: https://github.com/ocean/ecto_libsql
