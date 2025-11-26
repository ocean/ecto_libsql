# ecto_libsql Rust NIF

Rust Native Implemented Functions (NIFs) for the `ecto_libsql` Elixir library.

## Overview

This Rust crate provides the native bridge between Elixir and the LibSQL database client. It implements high-performance database operations using the [libsql-client](https://crates.io/crates/libsql-client) Rust library and exposes them to Elixir via [Rustler](https://github.com/rusterlium/rustler).

## Features

- **Connection Management**: Local SQLite files, remote Turso databases, and embedded replicas with sync
- **Query Execution**: Parameterised queries with support for multiple data types
- **Transactions**: Full transaction support with multiple isolation levels (DEFERRED, IMMEDIATE, EXCLUSIVE, READ_ONLY)
- **Prepared Statements**: Statement preparation and reuse for improved performance
- **Batch Operations**: Execute multiple statements atomically or independently
- **Cursors**: Stream large result sets efficiently
- **Vector Search**: Native support for vector similarity operations
- **Database Encryption**: AES-256-CBC encryption for local databases
- **Thread-Safe Registries**: Concurrent access to connections, transactions, statements, and cursors using Mutex-protected HashMaps
- **Production-Ready Error Handling**: All errors return proper Elixir error tuples instead of panicking (see Reliability section below)

## Reliability (v0.5.0+)

As of version 0.5.0, the NIF implements comprehensive error handling to ensure production stability:

- **Zero Panics**: Eliminated all 146 `unwrap()` calls from production code
- **Safe Mutex Locking**: Custom `safe_lock()` helpers handle poisoned mutexes gracefully
- **Proper Error Propagation**: All errors return `{:error, message}` tuples to Elixir
- **VM Protection**: NIF errors never crash the BEAM VM
- **Descriptive Errors**: All error messages include context for easier debugging

### Error Handling Pattern

The codebase uses safe error handling throughout:

```rust
// Helper functions for safe mutex locking
fn safe_lock<'a, T>(mutex: &'a Mutex<T>, context: &str) 
    -> Result<MutexGuard<'a, T>, rustler::Error>

// Usage pattern
let conn_map = safe_lock(&CONNECTION_REGISTRY, "function_name")?;
let client = conn_map.get(conn_id)
    .ok_or_else(|| rustler::Error::Term(Box::new("Connection not found")))?;
```

This ensures that all error paths return to Elixir for proper handling by supervision trees.

## Building

The NIF is built automatically when you compile the `ecto_libsql` Elixir project:

```bash
mix deps.get
mix compile
```

To build the Rust code separately:

```bash
cd native/ecto_libsql
cargo build --release
```

## Testing

Run Rust unit and integration tests:

```bash
cd native/ecto_libsql
cargo test
```

## Architecture

The NIF uses a registry-based architecture where:
- Each connection, transaction, statement, and cursor is assigned a unique UUID
- Thread-safe HashMaps (protected by Mutex) store these entities
- Elixir code references entities by UUID, ensuring safe concurrent access
- All registry operations use safe locking to prevent panics from mutex poisoning
- Invalid UUIDs return descriptive errors rather than panicking

## Resources

- [Rustler Documentation](https://docs.rs/rustler/)
- [LibSQL Client Documentation](https://docs.rs/libsql-client/)
- [Main Project Repository](https://github.com/ocean/ecto_libsql)
