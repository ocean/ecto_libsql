# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.6.0] - 2025-11-30

### Fixed

- **Remote Sync Performance & Reliability**
  - Removed redundant manual `.sync()` calls after write operations for embedded replicas
  - LibSQL automatically handles sync to remote primary database - manual syncs were causing double-sync overhead
  - Added 30-second timeout to connection establishment to prevent indefinite hangs
  - All Turso remote tests now pass reliably (previously 4 tests timed out)
  - Test suite execution time improved significantly (~107s vs timing out at 60s+)

- **Ecto Migrations Compatibility (Issue #20)**
  - Fixed DDL function grouping that was causing compilation errors
  - Added comprehensive migration test suite (759 lines) covering all SQLite ALTER TABLE operations
  - Improved handling of SQLite's limited ALTER TABLE support
  - Added tests for column operations, constraint management, and index creation

- **Prepared Statement Execution**
  - Fixed panic in prepared statement execution that could crash the BEAM VM
  - Added proper error handling for prepared statement operations
  - Improved error messages for prepared statement failures

- **Extended LibSQL DDL Support**
  - Added support for additional ALTER TABLE operations compatible with LibSQL
  - Improved DDL operation grouping and execution order
  - Better handling of SQLite dialect quirks

### Added

- **Cursor Streaming Support**
  - Implemented cursor-based streaming for large result sets
  - Added `handle_declare/4`, `handle_fetch/4`, and `handle_deallocate/4` DBConnection callbacks
  - Memory-efficient processing of large queries
  - Rust NIF functions: `declare_cursor/3`, `fetch_cursor/2`, cursor registry management

- **Comprehensive Test Coverage**
  - Added 138 new DDL generation tests in `test/ecto_connection_test.exs`
  - Added 759 lines of migration tests in `test/ecto_migration_test.exs`
  - Improved error handling test coverage
  - All 162 tests passing (0 failures)

### Changed

- **Sync Behaviour for Embedded Replicas**
  - Automatic sync after writes has been removed (LibSQL handles this natively)
  - Manual `sync()` via `EctoLibSql.Native.sync/1` still available for explicit control
  - Improved sync timeout handling with configurable `DEFAULT_SYNC_TIMEOUT_SECS` (30s)
  - Added connection timeout to prevent hangs during initial replica sync

- **Documentation Updates**
  - Updated all documentation to reflect sync behaviour changes
  - Added clarification about when manual sync is needed vs automatic
  - Improved Turso/LibSQL compatibility documentation references

### Technical Details

**Sync Performance Before:**
- Manual `.sync()` called after every write operation
- Double sync overhead (LibSQL auto-sync + manual sync)
- 120-second timeout causing long test hangs
- 4 tests timing out after 60+ seconds each

**Sync Performance After:**
- LibSQL's native auto-sync used correctly
- No redundant manual sync calls
- 30-second connection timeout for fast failure
- All tests passing in ~107 seconds

**Key Insight:**
According to Turso documentation: "Writes are sent to the remote primary database by default, then the local database updates automatically once the remote write succeeds." Manual sync is only needed when explicitly pulling down changes from remote (e.g., after reconnecting to an existing replica).

### Migration Notes

This is a **non-breaking change** for normal usage. However, if you were relying on automatic sync behaviour after writes in embedded replica mode, you may now need to explicitly call `EctoLibSql.Native.sync/1` when you need to ensure remote data is pulled down (e.g., after reconnecting to an existing local database).

**Recommended Actions:**
1. Review code that uses embedded replicas with `sync: true`
2. Add explicit `sync()` calls after reconnecting to existing local databases if you need to pull down remote changes
3. Remove any redundant manual `sync()` calls after write operations

## [0.5.0] - 2025-11-27

### Changed

- **Rust NIF Error Handling (BREAKING for direct NIF users)**
  - Eliminated all 146 `unwrap()` calls from production Rust code
  - Added `safe_lock()` and `safe_lock_arc()` helper functions for safe mutex locking
  - All NIF errors now return `{:error, message}` tuples to Elixir instead of panicking
  - Mutex poisoning errors are handled gracefully with descriptive context
  - Invalid connection/transaction/statement/cursor IDs return proper errors

### Fixed

- **VM Stability** - NIF errors no longer crash the entire BEAM VM
  - Invalid operations (bad connection IDs, missing resources) now return error tuples
  - Processes survive NIF errors, allowing supervision trees to work properly
  - Error messages include descriptive context for easier debugging

### Added

- **Comprehensive Error Handling Tests**
  - Added `test/error_demo_test.exs` with 7 tests demonstrating graceful error handling
  - Added `test/error_handling_test.exs` with 14 comprehensive error coverage tests
  - All tests verify that NIF errors return proper error tuples instead of crashing the BEAM VM

### Technical Details

**Before 0.5.0:**
- 146 `unwrap()` calls in Rust production code
- Mutex/registry errors → panic → entire BEAM VM crash
- Invalid IDs → panic → VM crash
- Supervision trees ineffective for NIF errors

**After 0.5.0:**
- 0 `unwrap()` calls in Rust production code (100% eliminated)
- All errors return `{:error, "descriptive message"}` tuples
- Processes can handle errors and recover
- Supervision trees work as expected

### Migration Guide

This is a **non-breaking change** for normal Ecto usage. Your existing code will continue to work exactly as before, but is now significantly more stable.

**What Changed:**
- NIF functions that previously panicked now return `{:error, reason}` tuples
- Your existing error handling code will now catch errors that previously crashed the VM

**Recommended Actions:**
1. Review error handling in code that uses `EctoLibSql.Native` functions directly
2. Ensure supervision strategies are in place for database operations
3. Consider adding retry logic for transient errors (connection timeouts, etc.)

### Notes

This release represents a major stability improvement for production deployments. The refactoring ensures that `ecto_libsql` handles errors the "Elixir way" - returning error tuples that can be supervised, rather than panicking at the Rust level and crashing the VM.

## [0.4.0] - 2025-11-19

### Changed

- **Library Renamed from LibSqlEx to EctoLibSql**
  - Package name changed from `:libsqlex` to `:ecto_libsql`
  - Main module renamed from `LibSqlEx` to `EctoLibSql`
  - Adapter module renamed from `Ecto.Adapters.LibSqlEx` to `Ecto.Adapters.LibSql`
  - Connection module renamed from `Ecto.Adapters.LibSqlEx.Connection` to `Ecto.Adapters.LibSql.Connection`
  - Native module renamed from `LibSqlEx.Native` to `EctoLibSql.Native`
  - All supporting modules updated (Query, Result, State, Error)
  - Rust crate renamed from `libsqlex` to `ecto_libsql`

### Migration Guide

To upgrade from 0.3.0 to 0.4.0, update your dependencies and module references:

```elixir
# mix.exs - Update dependency
def deps do
  [
    # Old: {:libsqlex, "~> 0.3.0"}
    {:ecto_libsql, "~> 0.4.0"}
  ]
end

# config/config.exs - Update adapter reference
config :my_app, MyApp.Repo,
  # Old: adapter: Ecto.Adapters.LibSqlEx
  adapter: Ecto.Adapters.LibSql

# Code - Update module references
# Old: alias LibSqlEx.{Query, Result}
alias EctoLibSql.{Query, Result}

# Old: LibSqlEx.Native.vector_type(128, :f32)
EctoLibSql.Native.vector_type(128, :f32)
```

All functionality remains identical; only names have changed.

## [0.3.0] - 2025-11-17

### Added

- **Full Ecto Adapter Support** - LibSqlEx now provides a complete Ecto adapter implementation
  - `Ecto.Adapters.LibSqlEx` - Main adapter module implementing Ecto.Adapter.Storage and Ecto.Adapter.Structure
  - `Ecto.Adapters.LibSqlEx.Connection` - SQL query generation and DDL support for SQLite/libSQL
  - Full support for Ecto schemas, changesets, and migrations
  - Phoenix integration support
  - Type loaders and dumpers for proper Ecto type conversion
  - Storage operations (create, drop, status)
  - Structure operations (dump, load) using sqlite3
  - Migration support with standard Ecto.Migration features:
    - CREATE/DROP TABLE with IF (NOT) EXISTS
    - ALTER TABLE for adding columns and renaming
    - CREATE/DROP INDEX with UNIQUE and partial index support
    - Proper constraint conversion (UNIQUE, FOREIGN KEY, CHECK)
  - Comprehensive test suite for adapter and connection modules

- **Documentation and Examples**
  - `examples/ecto_example.exs` - Complete Ecto usage examples
  - `ECTO_MIGRATION_GUIDE.md` - Comprehensive migration guide from PostgreSQL/MySQL
  - Updated README with extensive Ecto integration documentation
  - Phoenix integration guide
  - Production deployment best practices

### Changed

- Updated `mix.exs` to include `ecto` and `ecto_sql` dependencies
- Bumped version from 0.2.0 to 0.3.0 to reflect major feature addition

### Notes

This release makes LibSqlEx a full-featured Ecto adapter, bringing it on par with other database adapters in the Elixir ecosystem. Users can now:

- Use LibSqlEx in Phoenix applications
- Define Ecto schemas and run migrations
- Leverage all Ecto.Query features
- Benefit from Turso's remote replica mode with Ecto
- Migrate existing applications from PostgreSQL/MySQL to LibSqlEx

The adapter supports all three connection modes:
1. Local SQLite databases
2. Remote-only Turso connections
3. Remote replica mode (local + cloud sync)

### Breaking Changes

None - this is purely additive functionality.

### Known Limitations

SQLite/libSQL has some limitations compared to PostgreSQL:
- No ALTER COLUMN support (column type modifications require table recreation)
- No DROP COLUMN on older SQLite versions (< 3.35.0)
- No native array types (use JSON or separate tables)
- No native UUID type (stored as TEXT, works with Ecto.UUID)

These are SQLite limitations, not LibSqlEx limitations, and are well-documented in the migration guide.

## [0.2.0] - Previous Release

### Added

- DBConnection protocol implementation
- Local, Remote, and Remote Replica modes
- Transaction support with multiple isolation levels
- Prepared statements
- Batch operations
- Cursor support for large result sets
- Vector search support
- Encryption support (AES-256-CBC)
- WebSocket protocol support
- Metadata methods (last_insert_rowid, changes, etc.)

## [0.1.0] - Initial Release

### Added

- Basic LibSQL/Turso connection support
- Rust NIF implementation
- Query execution
- Basic transaction support
