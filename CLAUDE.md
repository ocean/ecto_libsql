# EctoLibSql - AI Agent Guide (Internal Development)

> **Purpose**: Comprehensive guide for AI agents working **ON** the ecto_libsql codebase itself
>
> **⚠️ IMPORTANT**: This guide is for **developing and maintaining** the ecto_libsql library.  
> **📚 For USING ecto_libsql in your applications**, see [AGENTS.md](AGENTS.md) instead, which covers real world usage of the library.

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

- ALWAYS use British/Australian English spelling and grammar for code, comments, and documentation, except where required for function calls etc that may be in US English, such as SQL keywords or error messages, or where required for compatibility with external systems.
- ALWAYS run the Elixir formatter (`mix format --check-formatted`) before committing changes and fix any issues.
- ALWAYS run the Rust Cargo formatter (`cargo fmt`) before committing changes and fix any issues.

---

## Project Overview

EctoLibSql is a **production-ready Ecto adapter** for LibSQL, implemented as a Rust NIF for high performance. It provides full Ecto integration for Elixir applications using LibSQL/SQLite-compatible databases.

### Key Features
- Full Ecto support (schemas, migrations, queries, associations)
- Three connection modes: Local SQLite, Remote Turso (libSQL), Embedded replica
- Vector search, encryption, prepared statements, batch operations
- High performance async/await with connection pooling

### Connection Modes
- **Local**: `database: "local.db"`
- **Remote**: `uri` + `auth_token`
- **Replica**: Local file + remote sync (`database` + `uri` + `auth_token` + `sync: true`)

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
│   ├── lib.rs                           # Root module (declares and exports all submodules)
│   ├── connection.rs                    # Connection lifecycle (open, close, health checks)
│   ├── query.rs                         # Query execution and result handling
│   ├── batch.rs                         # Batch operations (transactional & non-transactional)
│   ├── statement.rs                     # Prepared statement caching and execution
│   ├── transaction.rs                   # Transaction management with ownership tracking
│   ├── savepoint.rs                     # Savepoint operations (nested transactions)
│   ├── cursor.rs                        # Cursor streaming and pagination
│   ├── replication.rs                   # Remote replica sync and frame tracking
│   ├── metadata.rs                      # Metadata access (rowid, changes, etc.)
│   ├── utils.rs                         # Shared utilities (safe locking, error handling)
│   ├── constants.rs                     # Global registries and configuration
│   ├── models.rs                        # Core data structures (LibSQLConn, etc.)
│   ├── decode.rs                        # Value decoding and type conversions
│   └── tests/                           # Test modules
│       ├── mod.rs                       # Test module organisation
│       ├── constants_tests.rs           # Registry and constant tests
│       ├── utils_tests.rs               # Utility function tests
│       └── integration_tests.rs         # End-to-end integration tests
├── test/
│   ├── ecto_adapter_test.exs            # Adapter functionality tests
│   ├── ecto_connection_test.exs         # SQL generation tests
│   ├── ecto_integration_test.exs        # Full Ecto integration tests
│   ├── ecto_libsql_test.exs             # DBConnection tests
│   ├── ecto_migration_test.exs          # Migration tests
│   ├── error_handling_test.exs          # Error handling verification
│   └── turso_remote_test.exs            # Remote Turso tests
├── AGENTS.md                            # Comprehensive API documentation
├── CLAUDE.md                            # This file (AI agent guide)
├── README.md                            # User-facing documentation
├── CHANGELOG.md                         # Version history
├── ECTO_MIGRATION_GUIDE.md             # Migration from PostgreSQL/MySQL
├── RUST_ERROR_HANDLING.md              # Rust error patterns quick reference
├── RESILIENCE_IMPROVEMENTS.md          # Error handling refactoring details
└── TESTING.md                          # Testing strategy and organisation
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
**Responsibilities**: Connection lifecycle, transaction management, query execution, cursor operations

#### `EctoLibSql.Native` (lib/ecto_libsql/native.ex)
**Purpose**: Safe Elixir wrappers around Rust NIFs  
**Responsibilities**: State management, error handling, prepared statements, batch operations, metadata access, vector operations



#### `Ecto.Adapters.LibSql` (lib/ecto/adapters/libsql.ex)
**Purpose**: Main Ecto adapter  
**Responsibilities**: Storage operations, type loaders/dumpers, migration support, structure operations

#### `Ecto.Adapters.LibSql.Connection` (lib/ecto/adapters/libsql/connection.ex)
**Purpose**: SQL generation and DDL operations  
**Responsibilities**: Query compilation, DDL generation, expression building, constraint conversion  
**DDL Support**: CREATE/DROP TABLE/INDEX, ALTER TABLE, RENAME operations, foreign keys, constraints

#### `EctoLibSql.State` (lib/ecto_libsql/state.ex)
**Purpose**: Connection state tracking  
**Fields**: `:conn_id`, `:trx_id`, `:mode` (`:local`, `:remote`, `:remote_replica`), `:sync`

### Rust Code Structure

#### Module Organisation

The Rust codebase is organised into 14 focused modules, each with a single responsibility:

**`lib.rs` (29 lines)**
- Root module that declares and exports all submodules
- Performs NIF function registration via `rustler::init!`
- Re-exports key types (`constants::*`, `models::*`, utility functions)

**`models.rs` (61 lines) - Core Data Structures**
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

// Transaction entry with ownership tracking
pub struct TransactionEntry {
    pub conn_id: String,        // Which connection owns this transaction
    pub transaction: Transaction,
}
```

**`constants.rs` (63 lines) - Global Registries**
```rust
// Thread-safe global state
static ref TXN_REGISTRY: Mutex<HashMap<String, TransactionEntry>>  // Transaction ownership tracking
static ref STMT_REGISTRY: Mutex<HashMap<String, Arc<Mutex<Statement>>>>  // Prepared statement caching
static ref CURSOR_REGISTRY: Mutex<HashMap<String, CursorData>>
static ref CONNECTION_REGISTRY: Mutex<HashMap<String, Arc<Mutex<LibSQLConn>>>>
```

**`utils.rs` (400 lines)** - Safe locking, error handling, row collection, type conversions

**`connection.rs` (332 lines)** - Connection establishment, health checks, encryption, URI parsing

**`query.rs` (197 lines)** - Query execution with auto-routing, replica sync, result collection

**`statement.rs` (324 lines)** - Prepared statement caching, execution, parameter/column introspection

**`transaction.rs` (436 lines)** - Transaction management with ownership tracking and isolation levels

**`savepoint.rs` (135 lines)** - Nested transactions (create, release, rollback to savepoint)

**`batch.rs` (306 lines)** - Batch operations (transactional/non-transactional, raw SQL execution)

**`cursor.rs` (328 lines)** - Cursor streaming and pagination for large result sets

**`replication.rs` (205 lines)** - Remote replica frame tracking and synchronisation control

**`metadata.rs` (151 lines)** - Insert rowid, changes, total changes, autocommit status

**`decode.rs` (84 lines)** - Value type conversions (NULL, integer, text, blob, real)

#### Test Structure

Tests are organised into `tests/` subdirectory with focused modules:

**`tests/mod.rs` (8 lines)**
- Declares and organises all test modules

**`tests/constants_tests.rs` (44 lines)**
- Registry operations and constant validation

**`tests/utils_tests.rs` (627 lines)**
- Safe locking, row collection, query type detection
- Error handling and value decoding
- UUID generation and registry initialisation

**`tests/integration_tests.rs` (315 lines)**
- Real database operations with temporary SQLite files
- Connection lifecycle tests
- Full integration test scenarios

**Common Test Utilities**:
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
2. **Format code**: `mix format` and `cargo fmt`
3. **Run tests**: `mix test` and `cargo test`
4. **Check formatting**: `mix format --check-formatted`
5. **Commit changes** with descriptive message

### Adding New Features

#### Adding a New NIF Function

**IMPORTANT**: Modern Rustler (used in this project) automatically detects all NIFs annotated with `#[rustler::nif]`. The `rustler::init!` macro in `lib.rs` automatically discovers all functions with the `#[rustler::nif]` attribute.

1. **Identify the appropriate module** for your feature:
   - Connection lifecycle → `connection.rs`
   - Query execution → `query.rs`
   - Transactions → `transaction.rs`
   - Batch operations → `batch.rs`
   - Statements → `statement.rs`
   - Cursors → `cursor.rs`
   - Replication → `replication.rs`
   - Metadata → `metadata.rs`
   - Savepoints → `savepoint.rs`
   - Utilities → `utils.rs`

2. **Define Rust NIF** in the appropriate module (e.g., `native/ecto_libsql/src/query.rs`):
```rust
/// Execute a custom operation with the given connection.
///
/// # Arguments
/// - `conn_id` - Connection identifier
/// - `param` - Operation parameter
///
/// # Returns
/// - `{:ok, result}` - Operation succeeded
/// - `{:error, reason}` - Operation failed
#[rustler::nif(schedule = "DirtyIo")]
pub fn my_new_function(conn_id: &str, param: &str) -> NifResult<String> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "my_new_function")?;
    let _conn = conn_map
        .get(conn_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Connection not found")))?;

    // Implementation here
    Ok("result".to_string())
}
```

3. **Add Elixir NIF stub and wrapper** in `lib/ecto_libsql/native.ex`:
```elixir
# NIF stub (will be replaced by the Rust NIF when loaded)
def my_new_function(_conn, _param), do: :erlang.nif_error(:nif_not_loaded)

# Add safe wrapper that uses State
def my_new_function_safe(%EctoLibSql.State{conn_id: conn_id} = _state, param) do
  case my_new_function(conn_id, param) do
    {:ok, result} -> {:ok, result}
    {:error, reason} -> {:error, reason}
  end
end
```

4. **Add tests** in appropriate test modules:
   - Rust tests in `native/ecto_libsql/src/tests/` subdirectory
   - Create new test file if needed (e.g., `tests/feature_tests.rs`)
   - Elixir test in appropriate `test/` file

5. **Document** in `AGENTS.md` API Reference section and update `CHANGELOG.md`

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

```elixir
# Pattern 1: Case match
case EctoLibSql.Native.query(state, sql, params) do
  {:ok, _, result, new_state} -> # Handle success
  {:error, reason} -> # Handle error
end

# Pattern 2: With clause
with {:ok, state} <- EctoLibSql.connect(opts),
     {:ok, _, result, state} <- EctoLibSql.handle_execute(sql, [], [], state) do
  :ok
else
  {:error, reason} -> handle_error(reason)
end
```

---

## Testing Strategy

### Test Organisation & Running

**Elixir tests**: `test/*.exs` (adapter, connection, integration, migration, error handling, Turso)

**Rust tests**: `native/ecto_libsql/src/tests/` (structured modules)

```bash
# Quick start
mix test                                    # All Elixir tests
cd native/ecto_libsql && cargo test         # All Rust tests

# Specific
mix test test/ecto_integration_test.exs     # Single file
mix test test/ecto_integration_test.exs:42  # Single test
mix test --trace                            # With trace
mix test --exclude turso_remote             # Skip Turso tests
```

### Test Coverage Areas

**Must have tests for**:
- Happy path (successful operations)
- Error cases (invalid IDs, missing resources, constraint violations)
- Edge cases (NULL values, empty strings, large datasets)
- Transaction rollback scenarios
- Type conversions (Elixir ↔ SQLite)
- Concurrent operations (if applicable)

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

### Task 2: Fix Type Conversion Issues

Update loaders/dumpers in `lib/ecto/adapters/libsql.ex`:
```elixir
def loaders(:boolean, type), do: [&bool_decode/1, type]
defp bool_decode(0), do: {:ok, false}
defp bool_decode(1), do: {:ok, true}

def dumpers(:boolean, type), do: [type, &bool_encode/1]
defp bool_encode(false), do: {:ok, 0}
defp bool_encode(true), do: {:ok, 1}
```

### Task 4: Working with Transaction Ownership

**Context**: Transactions are now tracked with their owning connection using `TransactionEntry` struct. All savepoint and transaction operations validate ownership.

1. **Understanding TransactionEntry**:
```rust
pub struct TransactionEntry {
    pub conn_id: String,        // Connection that owns this transaction
    pub transaction: Transaction, // The actual LibSQL transaction
}
```

2. **When accessing transactions from registry**:
```rust
let entry = txn_registry
    .get_mut(trx_id)
    .ok_or_else(|| rustler::Error::Term(Box::new("Transaction not found")))?;

// Access the transaction via entry.transaction
entry.transaction.execute(&sql, args).await
```

3. **Validating transaction ownership** (savepoint example):
```rust
if entry.conn_id != conn_id {
    return Err(rustler::Error::Term(Box::new(
        "Transaction does not belong to this connection",
    )));
}
```

4. **NIF signature updates**:
   - `savepoint(conn_id, trx_id, name)` - Added conn_id parameter for consistency
   - `release_savepoint(conn_id, trx_id, name)` - Validates ownership
   - `rollback_to_savepoint(conn_id, trx_id, name)` - Validates ownership
   - `commit_or_rollback_transaction(trx_id, conn_id, ...)` - Validates ownership

5. **Testing transaction ownership**:
```elixir
test "rejects savepoint from wrong connection" do
  {:ok, conn1} = EctoLibSql.connect([database: "test1.db"])
  {:ok, conn2} = EctoLibSql.connect([database: "test2.db"])
  
  {:ok, trx_id} = EctoLibSql.Native.begin_transaction(conn1.conn_id)
  
  # This should fail - transaction belongs to conn1, not conn2
  assert {:error, msg} = EctoLibSql.Native.savepoint(conn2.conn_id, trx_id, "sp1")
  assert msg =~ "does not belong to this connection"
end
```

### Task 3: Debug a Failing Test

- Run with trace: `mix test test/file.exs:123 --trace`
- Check Rust output: `cd native/ecto_libsql && cargo test -- --nocapture`
- Verify NIF loading: `File.exists?("priv/native/ecto_libsql.so")`

### Task 4: Mark Functions as Explicitly Unsupported

**Pattern**: When a function promised in the public API cannot be implemented due to architectural constraints, explicitly mark it as unsupported rather than hiding it or returning vague errors.

**Example**: The `freeze_database` NIF (promoting a replica to primary) cannot be implemented without deep refactoring of the connection pool architecture.

**Steps**:

1. **Update Rust NIF** to return a clear `:unsupported` atom error:
```rust
#[rustler::nif(schedule = "DirtyIo")]
fn freeze_database(conn_id: &str) -> NifResult<Atom> {
    // Verify connection exists (basic validation)
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "freeze_database")?;
    let _exists = conn_map
        .get(conn_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Connection not found")))?;
    drop(conn_map);

    // Return typed error: :unsupported atom
    Err(rustler::Error::Atom("unsupported"))
}
```

2. **Update Elixir wrapper** to document unsupported status clearly:
```elixir
@doc """
Freeze a remote replica, converting it to a standalone local database.

⚠️ **NOT SUPPORTED** - This function is currently not implemented.

Freeze is intended to ... However, this operation requires deep refactoring of the
connection pool architecture and remains unimplemented. Instead, you can:

- **Option 1**: Backup the replica database file and use it independently
- **Option 2**: Replicate all data to a new local database
- **Option 3**: Keep the replica and manage failover at the application level

Always returns `{:error, :unsupported}`.

## Implementation Status

- **Blocker**: Requires taking ownership of the `Database` instance
- **Work Required**: Refactoring connection pool architecture
- **Timeline**: Uncertain - marked for future refactoring

See CLAUDE.md for technical details on why this is not currently supported.
"""
def freeze_replica(%EctoLibSql.State{conn_id: conn_id} = _state) when is_binary(conn_id) do
  {:error, :unsupported}
end
```

3. **Add comprehensive tests** asserting unsupported behavior:
```elixir
describe "freeze_replica - NOT SUPPORTED" do
  test "returns :unsupported atom for any valid connection" do
    {:ok, state} = EctoLibSql.connect(database: ":memory:")
    result = EctoLibSql.Native.freeze_replica(state)
    assert result == {:error, :unsupported}
    EctoLibSql.disconnect([], state)
  end

  test "freeze does not modify database" do
    {:ok, state} = EctoLibSql.connect(database: ":memory:")
    
    # Create and populate table
    {:ok, _, _, state} = EctoLibSql.handle_execute(
      "CREATE TABLE test (id INTEGER PRIMARY KEY, data TEXT)",
      [], [], state
    )
    {:ok, _, _, state} = EctoLibSql.handle_execute(
      "INSERT INTO test (data) VALUES (?)", ["value"], [], state
    )
    
    # Call freeze - should fail gracefully
    assert EctoLibSql.Native.freeze_replica(state) == {:error, :unsupported}
    
    # Verify data is still accessible
    {:ok, _, result, _state} = EctoLibSql.handle_execute(
      "SELECT data FROM test WHERE id = 1", [], [], state
    )
    assert result.rows == [["value"]]
    
    EctoLibSql.disconnect([], state)
  end
end
```

4. **Verify tests pass**: `mix test test/file_test.exs`

**Why This Pattern?**:
- **Honest API**: Users know the operation is unsupported rather than failing mysteriously
- **Clear error codes**: `:unsupported` atom is unambiguous (not a generic string error)
- **Future-proof docs**: Documentation explains why and what workarounds exist
- **No hidden behavior**: Function is a no-op that doesn't corrupt state
- **Comprehensive tests**: Prevent accidental "fixes" that break in production

---

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
libsql = { version = "0.9.29", features = ["encryption"] }

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

| Behavior | Use Case |
|----------|----------|
| `:deferred` | Default: lock on first write |
| `:immediate` | Write-heavy workloads |
| `:exclusive` | Critical operations (exclusive lock) |
| `:read_only` | Read-only queries |

### Ecto Type Mappings

| Ecto | SQLite | Notes |
|------|--------|-------|
| `:id`, `:integer` | INTEGER | Auto-increment for PK |
| `:binary_id` | TEXT | UUID string |
| `:string`, `:text` | TEXT | Variable/long text |
| `:boolean` | INTEGER | 0=false, 1=true |
| `:float`, `:decimal` | REAL/TEXT | Double precision/Decimal string |
| `:binary` | BLOB | Binary data |
| `:map` | TEXT | JSON |
| `:date`, `:time`, `:*_datetime` | TEXT | ISO8601 format |

### Important Commands

```bash
# Format & checks (ALWAYS before commit)
mix format --check-formatted && cd native/ecto_libsql && cargo fmt

# Run tests
mix test                                    # All Elixir
cd native/ecto_libsql && cargo test         # All Rust
mix test test/file.exs:42 --trace           # Specific

# Lint & quality
cd native/ecto_libsql && cargo clippy

# Docs
mix docs
```

---

## Resources & Further Reading

### Documentation Files (In This Repo)

- **AGENTS.md** - Complete API reference with examples
- **README.md** - User-facing documentation and quick start
- **CHANGELOG.md** - Version history and migration notes
- **ECTO_MIGRATION_GUIDE.md** - Migrating from PostgreSQL/MySQL
- **RUST_ERROR_HANDLING.md** - Rust error patterns quick reference
- **RESILIENCE_IMPROVEMENTS.md** - Error handling refactoring details
- **TESTING.md** - Testing strategy, organisation, and best practices

### External Resources

**LibSQL & Turso**:
- [LibSQL Source Code](https://github.com/tursodatabase/libsql)
- [LibSQL Documentation](https://docs.turso.tech/libsql)
- [Turso Rust bindings docs](https://github.com/tursodatabase/libsql/tree/main/libsql)
- [Turso Rust SDK docs](https://docs.turso.tech/sdk/rust/quickstart)

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
- [SQLite Source Code](https://github.com/sqlite/sqlite)

---

## Version History

Check the [CHANGELOG.md](CHANGELOG.md) file for details.

---

## Contributing Guidelines

When working on this codebase:

1. **ALWAYS format before committing**: `mix format --check-formatted`
2. **NEVER use `.unwrap()` in Rust production code** - use `safe_lock` helpers
3. **Add tests** for new features
4. **Update CHANGELOG.md** and relevant documentation
5. **Run both test suites**: `mix test` and `cargo test`
6. **Follow existing patterns** - grep for similar code first
7. **Include error handling** - every NIF returns proper error tuples

**Pre-submission checklist**: Format passes, tests pass, no `.unwrap()` in production Rust, new features tested, documentation updated.

---

## Summary

EctoLibSql is a production-ready Ecto adapter for LibSQL/Turso with full Ecto support, three connection modes, advanced features (vector search, encryption, streaming), zero panic risk, extensive test coverage, and comprehensive documentation.

**Key Principle**: Safety first. All Rust code uses proper error handling to protect the BEAM VM. Errors are returned as tuples that can be supervised gracefully.

**For agents**: Follow critical rules (formatting, Rust error handling), use existing patterns, test thoroughly. This is production code.

---

**Last Updated**: 2025-12-16
**Maintained By**: ocean  
**License**: Apache 2.0  
**Repository**: https://github.com/ocean/ecto_libsql
