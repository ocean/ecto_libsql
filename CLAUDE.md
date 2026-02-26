# EctoLibSql - AI Agent Development Guide

> **Purpose**: Guide for AI agents working **ON** the ecto_libsql codebase itself
>
> **⚠️ IMPORTANT**: This guide is for **developing and maintaining** the ecto_libsql library.
> **⚠️ IMPORTANT**: For **USING** ecto_libsql in applications, see [USAGE.md](USAGE.md) instead.

---

## Quick Rules

- **British/Australian English** for all code, comments, and documentation (except SQL keywords and compatibility requirements)
- **⚠️ CRITICAL: ALWAYS check formatting BEFORE committing**:
  1. Run formatters: `mix format && cd native/ecto_libsql && cargo fmt`
  2. Verify checks pass: `mix format --check-formatted && cargo fmt --check`
  3. **Only then** commit: `git commit -m "..."`
- **NEVER use `.unwrap()` in production Rust code** — use `safe_lock` helpers (see [Error Handling](#error-handling-patterns))
- **Tests MAY use `.unwrap()`** for simplicity

---

## Landing the Plane (Session Completion)

**MANDATORY WORKFLOW — work is NOT complete until `git commit` succeeds:**

1. **File issues for remaining work** — create Beads issues for anything needing follow-up
2. **Run quality gates** (if code changed) — tests, linters, builds
3. **Update issue status** — close finished work, update in-progress items
4. **COMMIT**:
   ```bash
   git commit -m "Your commit message"
   bd sync
   ```
5. **Clean up** — clear stashes, prune remote branches
6. **Verify** — all changes committed
7. **Hand off** - provide context for next session

**If commit fails, resolve and retry until it succeeds.**

---

## Project Overview

**EctoLibSql** is a production-ready Ecto adapter for LibSQL, implemented as a Rust NIF for high performance.

**Connection modes:**
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

**Elixir:**
- `lib/ecto_libsql.ex` — DBConnection protocol
- `lib/ecto_libsql/native.ex` — NIF wrappers
- `lib/ecto_libsql/state.ex` — Connection state
- `lib/ecto/adapters/libsql.ex` — Main adapter
- `lib/ecto/adapters/libsql/connection.ex` — SQL generation

**Rust** (`native/ecto_libsql/src/`):

| Module | Purpose |
|--------|---------|
| `lib.rs` | Root module, NIF registration |
| `models.rs` | Core structs (`LibSQLConn`, `CursorData`, `TransactionEntry`) |
| `constants.rs` | Global registries (connections, transactions, statements, cursors) |
| `utils.rs` | Safe locking, error handling, row collection, type conversions |
| `connection.rs` | Connection establishment, health checks, encryption |
| `query.rs` | Query execution, auto-routing, replica sync |
| `statement.rs` | Prepared statement caching, parameter/column introspection |
| `transaction.rs` | Transaction management, ownership tracking, isolation levels |
| `savepoint.rs` | Nested transactions (create, release, rollback) |
| `batch.rs` | Batch operations (transactional/non-transactional) |
| `cursor.rs` | Cursor streaming, pagination for large result sets |
| `replication.rs` | Replica frame tracking, synchronisation control |
| `metadata.rs` | Insert rowid, changes, autocommit status |
| `decode.rs` | Value type conversions |
| `tests/` | Test modules |

**Tests:**
- `test/*.exs` — Elixir tests (adapter, integration, migrations, error handling, Turso)
- `native/ecto_libsql/src/tests/` — Rust tests (constants, utils, integration)

### Key Data Structures

```rust
pub struct LibSQLConn {
    pub db: libsql::Database,
    pub client: Arc<Mutex<libsql::Connection>>,
}

pub struct TransactionEntry {
    pub conn_id: String,        // Which connection owns this transaction.
    pub transaction: Transaction,
}

pub struct CursorData {
    pub columns: Vec<String>,
    pub rows: Vec<Vec<Value>>,
    pub position: usize,
}
```

---

## Development Workflow

### Branch Strategy

**ALWAYS branch from `main`** for new work:

```bash
git checkout main && git pull origin main
git checkout -b feature-descriptive-name   # or bugfix-descriptive-name
```

### ⚠️ CRITICAL: Preserving Untracked Files

- **NEVER run `git clean`** without explicit user approval
- **NEVER run `git checkout .`** or `git restore .` on the whole repo
- **NEVER run `git reset --hard`** without explicit user approval
- Untracked files stay in place across branch switches — this is expected

### PR Workflow

All changes go through PRs to `main`:

```bash
git push -u origin feature-descriptive-name
gh pr create --base main --title "feat: description" --body "..."
```

After merge:
```bash
git checkout main && git pull origin main
git branch -d feature-descriptive-name
```

### Pre-Commit Checklist

**STRICT ORDER — do NOT skip steps or reorder:**

```bash
# 1. Format code (must come FIRST)
mix format && cd native/ecto_libsql && cargo fmt

# 2. Run tests (catch logic errors)
mix test && cd native/ecto_libsql && cargo test

# 3. Verify formatting checks (MUST PASS before commit)
mix format --check-formatted && cd native/ecto_libsql && cargo fmt --check

# 4. Lint (optional but recommended)
cd native/ecto_libsql && cargo clippy

# 5. Only commit if all checks above passed
git commit -m "feat: descriptive message"
```

**If ANY check fails, fix it and re-run before proceeding. Never commit with failing checks.**

---

## Issue Tracking with Beads

This project uses **Beads** (`bd` command) for issue tracking across sessions. Beads persists work context in `.beads/issues.jsonl`.

```bash
# Finding work
bd ready                           # Show issues ready to work (no blockers)
bd list --status=open              # All open issues
bd show <id>                       # Detailed issue view with dependencies

# Creating & updating (priority: 0-4, NOT "high"/"low")
bd create --title="..." --description="..." --type=task|bug|feature --priority=2
bd update <id> --status=in_progress
bd close <id>                      # Or: bd close <id1> <id2> ...

# Dependencies
bd dep add <issue> <depends-on>    # Add dependency
bd blocked                         # Show all blocked issues

# Sync & health
bd sync --from-main                # Pull beads updates from main
bd stats                           # Project statistics
bd doctor                          # Check for issues
bd prime                           # Session recovery after compaction
```

**Typical workflow:**
```bash
bd ready
bd show <id> && bd update <id> --status=in_progress
# ... do work ...
bd close <id1> <id2> ...
bd sync --from-main
git add . && git commit -m "..."
```

---

## Adding a New NIF Function

**Modern Rustler auto-detects all `#[rustler::nif]` functions — no manual registration needed.**

1. **Choose the right module** — connection lifecycle → `connection.rs`, query execution → `query.rs`, transactions → `transaction.rs`, batch → `batch.rs`, statements → `statement.rs`, cursors → `cursor.rs`, replication → `replication.rs`, metadata → `metadata.rs`, savepoints → `savepoint.rs`
2. **Define the Rust NIF** with `#[rustler::nif(schedule = "DirtyIo")]` — use `safe_lock` (never `.unwrap()`) — see [Error Handling](#error-handling-patterns)
3. **Add Elixir wrapper** in `lib/ecto_libsql/native.ex` — NIF stub + safe wrapper using `EctoLibSql.State`
4. **Add tests** in both Rust (`native/ecto_libsql/src/tests/`) and Elixir (`test/`)
5. **Update documentation** in `USAGE.md` and `CHANGELOG.md`

## Adding an Ecto Feature

1. Update `lib/ecto/adapters/libsql/connection.ex` for SQL generation
2. Update `lib/ecto/adapters/libsql.ex` for storage/type handling
3. Add tests in `test/ecto_*_test.exs`
4. Update `USAGE.md`

---

## Error Handling Patterns

### Rust Patterns (CRITICAL!)

**NEVER use `.unwrap()` in production code** — see `RUST_ERROR_HANDLING.md` for comprehensive patterns.

#### Pattern 1: Lock a Registry
```rust
✅ let conn_map = safe_lock(&CONNECTION_REGISTRY, "function_name context")?;
❌ let conn_map = CONNECTION_REGISTRY.lock().unwrap();
```

#### Pattern 2: Lock Arc<Mutex<T>>
```rust
✅ let client_guard = safe_lock_arc(&client, "function_name client")?;
❌ let result = client.lock().unwrap();
```

#### Pattern 3: Handle Options
```rust
✅ let conn = conn_map
    .get(conn_id)
    .ok_or_else(|| rustler::Error::Term(Box::new("Connection not found")))?;
❌ let conn = conn_map.get(conn_id).unwrap();
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
drop(conn_map); // Release lock before async work!

TOKIO_RUNTIME.block_on(async { /* async work */ })
```

### Elixir Patterns

```elixir
# Case match.
case EctoLibSql.Native.query(state, sql, params) do
  {:ok, _, result, new_state} -> handle_success(result)
  {:error, reason} -> handle_error(reason)
end

# With clause.
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
cd native/ecto_libsql && cargo test -- --nocapture  # Rust output with stdout
for i in {1..10}; do mix test test/file.exs:42; done # Flush out race conditions
```

### Test Variable Naming Conventions

Use consistent variable names by scope:

```elixir
state      # Connection scope
trx_state  # Transaction scope
cursor     # Cursor scope
stmt_id    # Prepared statement ID scope
```

**When an error operation returns updated state, decide if it's needed next:**

```elixir
# ✅ State IS needed → Rebind (add a clarifying comment)
# Rebind trx_state - error tuple contains updated transaction state needed for recovery.
assert {:error, _reason, trx_state} = result

# ✅ State is NOT needed → Discard with underscore
assert {:error, _reason, _state} = result

# ✅ Terminal operation → Underscore variable name
assert {:error, %EctoLibSql.Error{}, _conn} = EctoLibSql.handle_execute(...)
```

See [TEST_STATE_VARIABLE_CONVENTIONS.md](TEST_STATE_VARIABLE_CONVENTIONS.md) for detailed guidance.

### Turso Remote Tests

⚠️ **Cost Warning**: Creates real cloud databases. Only run when developing remote/replica functionality.

Create `.env.local`:
```
TURSO_DB_URI="libsql://your-database.turso.io"
TURSO_AUTH_TOKEN="your-token-here"
```

Run: `export $(grep -v '^#' .env.local | xargs) && mix test test/turso_remote_test.exs`

Tests are skipped by default if credentials are missing.

---

## Common Tasks

### Add SQLite Function Support

In `lib/ecto/adapters/libsql/connection.ex`:
```elixir
defp expr({:random, _, []}, _sources, _query), do: "RANDOM()"
```

### Fix Type Conversion Issues

In `lib/ecto/adapters/libsql.ex`:
```elixir
def loaders(:boolean, type), do: [&bool_decode/1, type]
defp bool_decode(0), do: {:ok, false}
defp bool_decode(1), do: {:ok, true}

def dumpers(:boolean, type), do: [type, &bool_encode/1]
defp bool_encode(false), do: {:ok, 0}
defp bool_encode(true), do: {:ok, 1}
```

### Work with Transaction Ownership

Always validate that a transaction belongs to the requesting connection:

```rust
if entry.conn_id != conn_id {
    return Err(rustler::Error::Term(Box::new(
        "Transaction does not belong to this connection",
    )));
}
```

### Mark Functions as Unsupported

1. Return `:unsupported` atom error in Rust
2. Document clearly in Elixir wrapper with alternatives
3. Add comprehensive tests asserting unsupported behaviour

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

---

## Resources

### Internal Documentation

- **[USAGE.md](USAGE.md)** — API reference for library users
- **[README.md](README.md)** — User-facing documentation
- **[CHANGELOG.md](CHANGELOG.md)** — Version history
- **[ECTO_MIGRATION_GUIDE.md](ECTO_MIGRATION_GUIDE.md)** — Migrating from PostgreSQL/MySQL
- **[RUST_ERROR_HANDLING.md](RUST_ERROR_HANDLING.md)** — Error pattern reference
- **[TESTING.md](TESTING.md)** — Testing strategy and organisation

### External Documentation

- [LibSQL Source](https://github.com/tursodatabase/libsql) | [LibSQL Docs](https://docs.turso.tech/libsql) | [Turso Rust SDK](https://docs.turso.tech/sdk/rust/quickstart)
- [Ecto Docs](https://hexdocs.pm/ecto/) | [Ecto.Query](https://hexdocs.pm/ecto/Ecto.Query.html) | [Ecto.Migration](https://hexdocs.pm/ecto_sql/Ecto.Migration.html)
- [Rustler Docs](https://github.com/rusterlium/rustler) | [SQLite Docs](https://www.sqlite.org/docs.html)

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

**Last Updated**: 2026-02-26 | **License**: Apache 2.0 | **Repository**: https://github.com/ocean/ecto_libsql
