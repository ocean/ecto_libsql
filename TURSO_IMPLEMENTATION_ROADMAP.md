# Turso Feature Implementation Roadmap

**Status**: Ready for Implementation
**Version**: 2.1.0 (Aligned with Ecto Adapter API)
**Last Updated**: 2025-12-02
**Based on**: Gap Analysis v3.2.0

This document outlines the implementation plan for closing the feature gap between `ecto_libsql` and the Turso/LibSQL Rust API, while ensuring full compliance with the **Ecto Adapter** specification.

---

## Phase 1: Critical Production Features (v0.7.0)

**Target Date**: Immediate
**Goal**: Stability, SQLite Compatibility, and Ecto Integration.

### 1. `busy_timeout` (P0) ✅ COMPLETED
**Problem**: Concurrent writes fail immediately with "database is locked".
**Ecto Integration**: Must be supported in `Ecto.Adapters.SQL.connect/1` options.
**Solution**: Expose `sqlite3_busy_timeout`.

- [x] **Rust**: Add `set_busy_timeout(conn_id, ms)` NIF.
  - Use `conn.busy_timeout(Duration::from_millis(ms))`.
- [x] **Elixir**: Update `EctoLibSql.Protocol.connect/1` to parse `:busy_timeout` option.
  - Default to `5000` (5 seconds) if not specified, matching standard Ecto/SQLite behaviour.
  - Call the NIF immediately after connection establishment.

### 2. PRAGMA Helpers (P0) ✅ COMPLETED
**Problem**: Configuring WAL, foreign keys, etc. is verbose.
**Ecto Integration**: Often done in `init/1` or migration scripts.
**Solution**: Add `EctoLibSql.Pragma` module.

- [x] **Rust**: Add `pragma_query(conn_id, pragma_stmt)` NIF.
- [x] **Elixir**: Create `EctoLibSql.Pragma` module.
  - `enable_foreign_keys(state)` / `disable_foreign_keys(state)` / `foreign_keys(state)`
  - `set_journal_mode(state, mode)` / `journal_mode(state)`
  - `set_synchronous(state, level)` / `synchronous(state)`
  - `table_info(state, table_name)` / `table_list(state)`
  - `user_version(state)` / `set_user_version(state, version)`
  - `query(state, pragma_stmt)` - Generic PRAGMA execution

### 3. Connection Reset & Interrupt (P1) ✅ COMPLETED
**Problem**: Need ability to reset connection state and interrupt long-running operations.
**Ecto Integration**: `DBConnection` expects connections to be reset when checked back into the pool.
**Solution**: Implement connection-level `reset` and `interrupt`.

- [x] **Rust**: Add `reset_connection(conn_id)` NIF.
- [x] **Rust**: Add `interrupt_connection(conn_id)` NIF.
- [x] **Elixir**: Add `reset(state)` wrapper in `EctoLibSql.Native`.
- [x] **Elixir**: Add `interrupt(state)` wrapper in `EctoLibSql.Native`.

### 4. Native Batch Execution (P1) ✅ COMPLETED
**Problem**: Need efficient multi-statement execution.
**Ecto Integration**: Useful for migrations and bulk operations.
**Solution**: Implement native batch execution with transactional option.

- [x] **Rust**: Add `execute_batch_native(conn_id, sql)` NIF.
- [x] **Rust**: Add `execute_transactional_batch_native(conn_id, sql)` NIF.
- [x] **Elixir**: Add `execute_batch_sql(state, sql)` wrapper.
- [x] **Elixir**: Add `execute_transactional_batch_sql(state, sql)` wrapper.

### 5. Statement Reuse & Reset (P1) 🚀
**Problem**: `ecto_libsql` re-prepares statements on every execution.
**Ecto Integration**: Ecto expects adapters to cache prepared statements.
**Solution**: Implement statement-level `reset` and fix statement lifecycle.

- [ ] **Rust**: Add `reset_statement(stmt_id)` NIF.
- [ ] **Rust**: Update `query_prepared` and `execute_prepared` to **NOT** re-prepare.
- [ ] **Elixir**: Implement `DBConnection.Query` protocol correctly to reuse cached statements.

---

## Phase 2: Ergonomics & Introspection (v0.8.0)

**Target Date**: Next Release
**Goal**: Better developer experience and Ecto Query compatibility.

### 6. `query_row` (P1)
**Problem**: Inefficient single-row fetches.
**Ecto Integration**: Used by `Ecto.Repo.get/3` and `one/2`.
**Solution**: Implement `query_row` for efficiency.

- [ ] **Rust**: Add `query_row(conn_id, stmt_id, args)` NIF.
- [ ] **Elixir**: Optimise `EctoLibSql.Connection.execute/4` to use `query_row` when `limit: 1` is detected (if possible via adapter flags).

### 7. Statement Introspection (P1)
**Problem**: Missing metadata.
**Ecto Integration**: Useful for `Ecto.Adapters.SQL.explain/4` and debugging.
**Solution**: Expose metadata.

- [ ] **Rust**: Add `statement_columns(stmt_id)` NIF.
- [ ] **Rust**: Add `statement_params_count(stmt_id)` NIF.

### 8. Named Parameters (P2)
**Problem**: Only positional `?` parameters.
**Ecto Integration**: Ecto typically uses positional parameters internally, but raw SQL queries might use named params.
**Solution**: Support `:name` style parameters.

- [ ] **Rust**: Update query NIFs to accept map/keyword list for params.

---

## Phase 3: Advanced Features (v0.9.0+)

**Target Date**: Future
**Goal**: Advanced capabilities.

### 9. Replication Control
- [ ] `sync_until(index)`
- [ ] `flush_replicator()`
- [ ] `freeze()`

### 10. Hooks
- [ ] `authorizer` callback
- [ ] `update_hook` callback

### 11. Extensions
- [ ] `load_extension(path)`

---

## Implementation Guidelines

1.  **No Unwraps**: Continue the v0.5.0 pattern. Return `Result<T, rustler::Error>`.
2.  **Async/Await**: Use `TOKIO_RUNTIME.block_on` for all async LibSQL calls.
3.  **Thread Safety**: Always use `safe_lock` and `safe_lock_arc`.
4.  **Testing**:
    -   Add Rust unit tests in `native/ecto_libsql/src/tests.rs`.
    -   Add Elixir integration tests in `test/` verifying `Ecto.Repo` behavior.
