# EctoLibSql - AI Agent Development Guide

> **Purpose**: Guide for AI agents working **ON** the ecto_libsql codebase itself
>
> **⚠️ IMPORTANT**: This guide is for **developing and maintaining** the ecto_libsql library.
> **⚠️ IMPORTANT**: For **USING** ecto_libsql in applications, see [AGENTS.md](AGENTS.md) instead.

---

## Quick Rules

- **British/Australian English** for all code, comments, and documentation (except SQL keywords and compatibility requirements)
- **ALWAYS format before committing**: `mix format --check-formatted` and `cargo fmt`
- **NEVER use `.unwrap()` in production Rust code** - use `safe_lock` helpers (see [Error Handling](#error-handling-patterns))
- **Tests MAY use `.unwrap()`** for simplicity

---

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git commit` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create Beads issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **COMMIT** - This is MANDATORY:
   ```bash
   git commit -m "Your commit message"
   bd sync
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git commit` succeeds
- If commit fails, resolve and retry until it succeeds

---

## Table of Contents

- [Project Overview](#project-overview)
- [Architecture](#architecture)
- [Code Structure](#code-structure)
- [Development Workflow](#development-workflow)
- [Error Handling Patterns](#error-handling-patterns)
- [Testing](#testing)
- [Common Tasks](#common-tasks)
- [Troubleshooting](#troubleshooting)
- [Quick Reference](#quick-reference)
- [Resources](#resources)

---

## Project Overview

**EctoLibSql** is a production-ready Ecto adapter for LibSQL, implemented as a Rust NIF for high performance.

### Features
- Full Ecto support (schemas, migrations, queries, associations)
- Three connection modes: Local SQLite, Remote Turso, Embedded replica
- Vector search, encryption, prepared statements, batch operations
- High-performance async/await with connection pooling

### Connection Modes
- **Local**: `database: "local.db"`
- **Remote**: `uri: "libsql://..." + auth_token: "..."`
- **Replica**: `database + uri + auth_token + sync: true`

---

## Architecture

### Layer Stack

```
Phoenix / Application
  ↓
Ecto.Adapters.LibSql (storage, type loaders/dumpers)
  ↓
Ecto.Adapters.LibSql.Connection (SQL generation, DDL)
  ↓
EctoLibSql (DBConnection protocol)
  ↓
EctoLibSql.Native (Rust NIF wrappers)
  ↓
Rust NIF (libsql-rs, connection registry, async runtime)
```

### Key Files

**Elixir**:
- `lib/ecto_libsql.ex` - DBConnection protocol
- `lib/ecto_libsql/native.ex` - NIF wrappers
- `lib/ecto_libsql/state.ex` - Connection state
- `lib/ecto/adapters/libsql.ex` - Main adapter
- `lib/ecto/adapters/libsql/connection.ex` - SQL generation

**Rust** (`native/ecto_libsql/src/`):
- `lib.rs` - Root module, NIF registration
- `models.rs` - Core data structures (`LibSQLConn`, `CursorData`, `TransactionEntry`)
- `constants.rs` - Global registries (connections, transactions, statements, cursors)
- `utils.rs` - Safe locking, error handling, type conversions
- `connection.rs` - Connection lifecycle
- `query.rs` - Query execution
- `transaction.rs` - Transaction management with ownership tracking
- `savepoint.rs` - Nested transactions
- `statement.rs` - Prepared statement caching
- `batch.rs` - Batch operations
- `cursor.rs` - Cursor streaming
- `replication.rs` - Replica sync
- `metadata.rs` - Metadata access
- `decode.rs` - Value type conversions
- `tests/` - Test modules

**Tests**:
- `test/*.exs` - Elixir tests (adapter, integration, migrations, error handling, Turso)
- `native/ecto_libsql/src/tests/` - Rust tests (constants, utils, integration)

**Documentation**:
- `AGENTS.md` - API reference for users
- `CLAUDE.md` - This file (development guide)
- `README.md` - User documentation
- `CHANGELOG.md` - Version history
- `ECTO_MIGRATION_GUIDE.md` - Migrating from PostgreSQL/MySQL
- `RUST_ERROR_HANDLING.md` - Error pattern reference
- `TESTING.md` - Testing strategy

---

## Code Structure

### Elixir Modules

| Module | Purpose |
|--------|---------|
| `EctoLibSql` | DBConnection protocol (lifecycle, transactions, queries, cursors) |
| `EctoLibSql.Native` | Safe NIF wrappers (error handling, state management) |
| `EctoLibSql.State` | Connection state (`:conn_id`, `:trx_id`, `:mode`, `:sync`) |
| `Ecto.Adapters.LibSql` | Main adapter (storage ops, type loaders/dumpers, migrations) |
| `Ecto.Adapters.LibSql.Connection` | SQL generation (queries, DDL, expressions, constraints) |

### Rust Module Organisation

14 focused modules, each with single responsibility:

| Module | Lines | Purpose |
|--------|-------|---------|
| `lib.rs` | 29 | Root module, NIF registration, re-exports |
| `models.rs` | 61 | Core structs (`LibSQLConn`, `CursorData`, `TransactionEntry`) |
| `constants.rs` | 63 | Global registries (connections, transactions, statements, cursors) |
| `utils.rs` | 400 | Safe locking, error handling, row collection, type conversions |
| `connection.rs` | 332 | Connection establishment, health checks, encryption |
| `query.rs` | 197 | Query execution, auto-routing, replica sync |
| `statement.rs` | 324 | Prepared statement caching, parameter/column introspection |
| `transaction.rs` | 436 | Transaction management, ownership tracking, isolation levels |
| `savepoint.rs` | 135 | Nested transactions (create, release, rollback) |
| `batch.rs` | 306 | Batch operations (transactional/non-transactional) |
| `cursor.rs` | 328 | Cursor streaming, pagination for large result sets |
| `replication.rs` | 205 | Replica frame tracking, synchronisation control |
| `metadata.rs` | 151 | Insert rowid, changes, autocommit status |
| `decode.rs` | 84 | Value type conversions (NULL, integer, text, blob, real) |

**Key Data Structures**:
```rust
// Connection resource
pub struct LibSQLConn {
    pub db: libsql::Database,
    pub client: Arc<Mutex<libsql::Connection>>,
}

// Transaction with ownership tracking
pub struct TransactionEntry {
    pub conn_id: String,        // Which connection owns this transaction
    pub transaction: Transaction,
}

// Cursor pagination state
pub struct CursorData {
    pub columns: Vec<String>,
    pub rows: Vec<Vec<Value>>,
    pub position: usize,
}
```

---

## Development Workflow

### Setup

```bash
git clone <repo-url>
cd ecto_libsql
mix deps.get
mix compile                        # Includes Rust NIF compilation
mix test
cd native/ecto_libsql && cargo test
```

### Development Cycle

1. Make changes to Elixir or Rust code
2. Format: `mix format && cargo fmt`
3. Run tests: `mix test && cargo test`
4. Check formatting: `mix format --check-formatted`
5. Commit with descriptive message

### Adding a New NIF Function

**IMPORTANT**: Modern Rustler auto-detects all `#[rustler::nif]` functions. No manual registration needed.

**Steps**:

1. **Choose the right module**:
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

2. **Define Rust NIF** (e.g., in `native/ecto_libsql/src/query.rs`):
```rust
/// Execute a custom operation.
///
/// # Returns
/// - `{:ok, result}` - Success
/// - `{:error, reason}` - Failure
#[rustler::nif(schedule = "DirtyIo")]
pub fn my_new_function(conn_id: &str, param: &str) -> NifResult<String> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "my_new_function")?;
    let _conn = conn_map
        .get(conn_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Connection not found")))?;
    
    // Implementation
    Ok("result".to_string())
}
```

3. **Add Elixir wrapper** in `lib/ecto_libsql/native.ex`:
```elixir
# NIF stub
def my_new_function(_conn, _param), do: :erlang.nif_error(:nif_not_loaded)

# Safe wrapper using State
def my_new_function_safe(%EctoLibSql.State{conn_id: conn_id} = _state, param) do
  case my_new_function(conn_id, param) do
    {:ok, result} -> {:ok, result}
    {:error, reason} -> {:error, reason}
  end
end
```

4. **Add tests** in both Rust (`native/ecto_libsql/src/tests/`) and Elixir (`test/`)

5. **Update documentation** in `AGENTS.md` and `CHANGELOG.md`

### Adding an Ecto Feature

1. Update `lib/ecto/adapters/libsql/connection.ex` for SQL generation
2. Update `lib/ecto/adapters/libsql.ex` for storage/type handling
3. Add tests in `test/ecto_*_test.exs`
4. Update README and AGENTS.md

---

## Error Handling Patterns

### Rust Patterns (CRITICAL!)

**NEVER use `.unwrap()` in production code** - all 146 unwrap calls eliminated in v0.5.0 to prevent VM crashes.

See `RUST_ERROR_HANDLING.md` for comprehensive patterns.

#### Pattern 1: Lock a Registry
```rust
✅ CORRECT
let conn_map = safe_lock(&CONNECTION_REGISTRY, "function_name context")?;

❌ WRONG - will panic!
let conn_map = CONNECTION_REGISTRY.lock().unwrap();
```

#### Pattern 2: Lock Arc<Mutex<T>>
```rust
✅ CORRECT
let client_guard = safe_lock_arc(&client, "function_name client")?;

❌ WRONG
let result = client.lock().unwrap();
```

#### Pattern 3: Handle Options
```rust
✅ CORRECT
let conn = conn_map
    .get(conn_id)
    .ok_or_else(|| rustler::Error::Term(Box::new("Connection not found")))?;

❌ WRONG
let conn = conn_map.get(conn_id).unwrap();
```

#### Pattern 4: Async Error Conversion
```rust
TOKIO_RUNTIME.block_on(async {
    let guard = safe_lock_arc(&client, "context")
        .map_err(|e| format!("{:?}", e))?;
    guard.query(sql, params).await.map_err(|e| format!("{:?}", e))
})
```

#### Pattern 5: Drop Locks Before Async
```rust
let conn_map = safe_lock(&CONNECTION_REGISTRY, "function")?;
let client = conn_map.get(conn_id).cloned()
    .ok_or_else(|| rustler::Error::Term(Box::new("Connection not found")))?;
drop(conn_map); // Release lock!

TOKIO_RUNTIME.block_on(async { /* async work */ })
```

### Elixir Patterns

```elixir
# Case match
case EctoLibSql.Native.query(state, sql, params) do
  {:ok, _, result, new_state} -> # Handle success
  {:error, reason} -> # Handle error
end

# With clause
with {:ok, state} <- EctoLibSql.connect(opts),
     {:ok, _, result, state} <- EctoLibSql.handle_execute(sql, [], [], state) do
  :ok
else
  {:error, reason} -> handle_error(reason)
end
```

---

## Testing

### Running Tests

```bash
mix test                                    # All Elixir tests
cd native/ecto_libsql && cargo test         # All Rust tests
mix test test/ecto_integration_test.exs     # Single file
mix test test/file.exs:42 --trace           # Single test with trace
mix test --exclude turso_remote             # Skip Turso tests
```

### Test Coverage Requirements

- Happy path (successful operations)
- Error cases (invalid IDs, missing resources, constraint violations)
- Edge cases (NULL values, empty strings, large datasets)
- Transaction rollback scenarios
- Type conversions (Elixir ↔ SQLite)
- Concurrent operations

### Turso Remote Tests

⚠️ **Cost Warning**: Creates real cloud databases. Only run when developing remote/replica functionality.

**Setup**: Create `.env.local`:
```
TURSO_DB_URI="libsql://your-database.turso.io"
TURSO_AUTH_TOKEN="your-token-here"
```

**Run**:
```bash
export $(grep -v '^#' .env.local | xargs) && mix test test/turso_remote_test.exs
```

Tests are skipped by default if credentials are missing.

---

## Common Tasks

### Add SQLite Function Support

If function is native to SQLite, update `lib/ecto/adapters/libsql/connection.ex`:

```elixir
defp expr({:random, _, []}, _sources, _query) do
  "RANDOM()"
end
```

Add test:
```elixir
test "generates RANDOM() function" do
  query = from u in User, select: fragment("RANDOM()")
  assert SQL.all(query) =~ "RANDOM()"
end
```

### Fix Type Conversion Issues

Update loaders/dumpers in `lib/ecto/adapters/libsql.ex`:

```elixir
def loaders(:boolean, type), do: [&bool_decode/1, type]
defp bool_decode(0), do: {:ok, false}
defp bool_decode(1), do: {:ok, true}

def dumpers(:boolean, type), do: [type, &bool_encode/1]
defp bool_encode(false), do: {:ok, 0}
defp bool_encode(true), do: {:ok, 1}
```

### Work with Transaction Ownership

Transactions track their owning connection via `TransactionEntry`:

```rust
pub struct TransactionEntry {
    pub conn_id: String,        // Connection that owns this transaction
    pub transaction: Transaction,
}
```

Always validate ownership:
```rust
if entry.conn_id != conn_id {
    return Err(rustler::Error::Term(Box::new(
        "Transaction does not belong to this connection",
    )));
}
```

### Mark Functions as Unsupported

When a function cannot be implemented due to architectural constraints:

1. Return `:unsupported` atom error in Rust
2. Document clearly in Elixir wrapper with alternatives
3. Add comprehensive tests asserting unsupported behaviour

Example: `freeze_database` (see full pattern in original CLAUDE.md if needed)

### Debug Failing Tests

```bash
mix test test/file.exs:123 --trace                  # Trace
cd native/ecto_libsql && cargo test -- --nocapture  # Rust output
mix clean && mix compile                            # Rebuild
for i in {1..10}; do mix test test/file.exs:42; done # Race conditions
```

### Pre-Commit Checklist

```bash
mix format && cd native/ecto_libsql && cargo fmt    # Format
mix test && cd native/ecto_libsql && cargo test     # Test
mix format --check-formatted                        # Verify format
cd native/ecto_libsql && cargo clippy               # Lint (optional)
git commit -m "feat: descriptive message"
```

### Release Process

1. Update version in `mix.exs`
2. Update `CHANGELOG.md`
3. Update `README.md` if needed
4. Run full test suite
5. Create release

**Hex package includes**: `lib/`, `priv/`, `native/`, documentation files  
**Hex package excludes**: `test/`, `examples/`, build artifacts

---

## Troubleshooting

### Database Locked

**Symptoms**: `** (EctoLibSql.Error) database is locked`

**Solutions**:
- Use proper transactions with timeout: `Repo.transaction(fn -> ... end, timeout: 15_000)`
- Ensure connections are closed in try/after blocks
- Use immediate transactions for writes: `begin(state, behavior: :immediate)`

### Type Conversion Errors

**Symptoms**: `** (Ecto.ChangeError) value does not match type`

**Solutions**:
- Verify schema types match database columns
- Check custom types have loaders/dumpers
- Use `cast/3` in changesets for automatic conversion

### Migration Fails

**Symptoms**: `** (Ecto.MigrationError) cannot alter column type`

**Cause**: SQLite doesn't support ALTER COLUMN; SQLite < 3.35.0 doesn't support DROP COLUMN

**Solution**: Use table recreation pattern (see `ECTO_MIGRATION_GUIDE.md`):
1. Create new table with desired schema
2. Copy data with transformation
3. Drop old table
4. Rename new table
5. Recreate indexes

### Turso Connection Fails

**Symptoms**: `** (EctoLibSql.Error) connection failed: authentication error`

**Solutions**:
- Verify credentials: `turso db show <name>` and `turso db tokens create <name>`
- Check URI includes `libsql://` prefix
- Use replica mode for better error handling (local fallback)

### Memory Leak Suspected

**Solutions**:
- Ensure cursors are deallocated (streams handle this automatically)
- Close connections properly with try/after
- Use connection pooling with appropriate limits

### Vector Search Not Working

**Symptoms**: `** (EctoLibSql.Error) no such function: vector`

**Solutions**:
- Verify LibSQL version in `native/ecto_libsql/Cargo.toml`
- Use correct vector syntax: `EctoLibSql.Native.vector_type(128, :f32)`
- Insert with `vector([...])` wrapper
- Query with distance functions: `vector_distance_cos("column", vec)`

---

## Quick Reference

### Connection Options

| Option | Type | Required For | Description |
|--------|------|--------------|-------------|
| `:database` | string | Local, Replica | Local SQLite file path |
| `:uri` | string | Remote, Replica | Turso database URI |
| `:auth_token` | string | Remote, Replica | Turso auth token |
| `:sync` | boolean | Replica | Auto-sync for replicas |
| `:encryption_key` | string | Optional | AES-256 encryption key (32+ chars) |
| `:pool_size` | integer | Optional | Connection pool size |

### Transaction Behaviours

| Behaviour | Use Case |
|-----------|----------|
| `:deferred` | Default: lock on first write |
| `:immediate` | Write-heavy workloads |
| `:exclusive` | Critical operations (exclusive lock) |
| `:read_only` | Read-only queries |

### Ecto Type Mappings

| Ecto Type | SQLite Type | Notes |
|-----------|-------------|-------|
| `:id`, `:integer` | INTEGER | Auto-increment for PK |
| `:binary_id` | TEXT | UUID string |
| `:string`, `:text` | TEXT | Variable/long text |
| `:boolean` | INTEGER | 0=false, 1=true |
| `:float`, `:decimal` | REAL/TEXT | Double precision/Decimal string |
| `:binary` | BLOB | Binary data |
| `:map` | TEXT | JSON |
| `:date`, `:time`, `:*_datetime` | TEXT | ISO8601 format |

### Essential Commands

```bash
# Format & checks (ALWAYS before commit)
mix format --check-formatted
cd native/ecto_libsql && cargo fmt

# Tests
mix test                                    # All Elixir
cd native/ecto_libsql && cargo test         # All Rust
mix test test/file.exs:42 --trace           # Specific with trace

# Quality
cd native/ecto_libsql && cargo clippy       # Lint

# Docs
mix docs                                    # Generate docs
```

---

## Resources

### Internal Documentation

- **[AGENTS.md](AGENTS.md)** - API reference for library users
- **[README.md](README.md)** - User-facing documentation
- **[CHANGELOG.md](CHANGELOG.md)** - Version history
- **[ECTO_MIGRATION_GUIDE.md](ECTO_MIGRATION_GUIDE.md)** - Migrating from PostgreSQL/MySQL
- **[RUST_ERROR_HANDLING.md](RUST_ERROR_HANDLING.md)** - Error pattern reference
- **[TESTING.md](TESTING.md)** - Testing strategy and organisation

### External Documentation

**LibSQL & Turso**:
- [LibSQL Source](https://github.com/tursodatabase/libsql)
- [LibSQL Docs](https://docs.turso.tech/libsql)
- [Turso Rust SDK](https://docs.turso.tech/sdk/rust/quickstart)

**Ecto**:
- [Ecto Docs](https://hexdocs.pm/ecto/)
- [Ecto.Query](https://hexdocs.pm/ecto/Ecto.Query.html)
- [Ecto.Migration](https://hexdocs.pm/ecto_sql/Ecto.Migration.html)

**Rust & NIFs**:
- [Rustler Docs](https://github.com/rusterlium/rustler)
- [Rust Book](https://doc.rust-lang.org/book/)
- [Async Rust](https://rust-lang.github.io/async-book/)

**SQLite**:
- [SQLite Docs](https://www.sqlite.org/docs.html)
- [SQLite Source](https://github.com/sqlite/sqlite)

---

## Contributing Checklist

1. ✅ Format code: `mix format && cargo fmt`
2. ✅ Run tests: `mix test && cargo test`
3. ✅ Verify formatting: `mix format --check-formatted`
4. ✅ No `.unwrap()` in production Rust code
5. ✅ Add tests for new features
6. ✅ Update `CHANGELOG.md` and relevant docs
7. ✅ Follow existing code patterns

---

## Summary

**EctoLibSql** is a production-ready Ecto adapter for LibSQL/Turso with:
- Full Ecto support (schemas, migrations, queries, associations)
- Three connection modes (local, remote, replica)
- Advanced features (vector search, encryption, streaming)
- Zero panic risk (proper error handling throughout)
- Extensive test coverage
- Comprehensive documentation

**Key Principle**: Safety first. All Rust code uses proper error handling to protect the BEAM VM. Errors are returned as tuples that can be supervised gracefully.

**For AI Agents**: Follow critical rules (formatting, Rust error handling), use existing patterns, test thoroughly. This is production code.

---

**Last Updated**: 2025-12-30  
**Maintained By**: ocean  
**License**: Apache 2.0  
**Repository**: https://github.com/ocean/ecto_libsql
