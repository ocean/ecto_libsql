# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **Major Rust Code Refactoring (Modularisation)**
  - Split monolithic `lib.rs` (2,302 lines) into 13 focused, single-responsibility modules
  - **Module structure by feature area**:
    - `connection.rs` - Connection lifecycle, establishment, and state management
    - `query.rs` - Basic query execution and result handling
    - `batch.rs` - Batch operations (transactional and non-transactional)
    - `statement.rs` - Prepared statement caching and execution
    - `transaction.rs` - Transaction management with ownership tracking
    - `savepoint.rs` - Nested transactions (savepoint operations)
    - `cursor.rs` - Cursor streaming and result pagination
    - `replication.rs` - Remote replica sync control and frame tracking
    - `metadata.rs` - Metadata access (rowid, changes, autocommit status)
    - `utils.rs` - Shared utilities (safe locking, error handling, row collection)
    - `constants.rs` - Global registries and configuration constants
    - `models.rs` - Core data structures (LibSQLConn, connection state)
    - `decode.rs` - Value decoding and type conversions
  - **Test reorganisation** - Refactored monolithic `tests.rs` (1,194 lines) into structured modules:
    - `tests/mod.rs` - Test module declaration and organisation
    - `tests/constants_tests.rs` - Registry and constant tests
    - `tests/utils_tests.rs` - Utility function and safety tests
    - `tests/integration_tests.rs` - End-to-end integration tests
  - **Root module simplification** - `lib.rs` now only declares modules and exports key types
  - **Improved maintainability** - Separation of concerns
  - **Zero behaviour changes** - Refactoring is purely organisational, all APIs and functionality preserved
  - **Enhanced documentation** - Module-level doc comments explain purpose and relationships
  - **Impact**: Significantly improved code navigation, maintenance, and onboarding for contributors

### Fixed

- **Prepared Statement Column Introspection Tests**
  - Enabled previously skipped tests for `stmt_column_count/2` and `stmt_column_name/3` features
  - Tests verify column metadata retrieval from prepared statements works correctly
  - Fixed test references to use correct NIF function names
  - Both simple and complex query scenarios now tested and passing

- **Critical Rust NIF Thread Safety and Scheduler Issues**
  - **Registry Lock Management**: Fixed all functions to drop registry locks before entering `TOKIO_RUNTIME.block_on()` async blocks
    - `execute_batch()` and `execute_transactional_batch()` in `batch.rs`: Simplified function signatures, dropped `conn_map` lock before async operations
    - `declare_cursor()` in `cursor.rs`: Dropped `conn_map` lock before async block
    - `do_sync()` in `query.rs`: Dropped `conn_map` lock before async block
    - `savepoint()`, `release_savepoint()`, and `rollback_to_savepoint()` in `savepoint.rs`: Now use `TransactionEntryGuard` pattern to avoid holding `TXN_REGISTRY` lock during async operations
    - `prepare_statement()` in `statement.rs`: Now clones inner connection Arc and drops client lock before async block, preventing locks from being held across await points
    - `begin_transaction()` and `begin_transaction_with_behavior()` in `transaction.rs`: Now clone inner connection Arc and drop all locks before async transaction creation, preventing locks from being held across await points
  - **DirtyIo Scheduler Annotations**: Added `#[rustler::nif(schedule = "DirtyIo")]` to blocking NIFs
    - `last_insert_rowid()`, `changes()`, and `is_autocommit()` in `metadata.rs`
    - Prevents blocking the BEAM scheduler during I/O operations
  - **Atom Naming Consistency**: Renamed `remote_primary` atom to `remote` in `constants.rs` and `decode.rs`
    - Fixes mismatch between Rust atom (`remote_primary()`) and Elixir convention (`:remote`)
    - `decode_mode()` now correctly decodes `:remote` atoms from Elixir
  - **Binary Allocation Error Handling**: Return `:error` atom instead of `nil` when binary allocation fails
    - Updated `cursor.rs` and `utils.rs` to use `:error` atom for `OwnedBinary::new()` allocation failures
    - Provides clearer indication of allocation errors in query results
  - **SQL Identifier Quoting**: Added proper quoting for SQLite identifiers in PRAGMA queries (`utils.rs`)
    - Table and index names are now properly quoted with double quotes
    - Internal double quotes are escaped by doubling them
    - Defensive programming against potential edge cases with special characters in identifiers
  - **Performance Optimizations**:
    - **Replication**: `max_write_replication_index()` in `replication.rs` now calls synchronous method directly instead of wrapping in `TOKIO_RUNTIME.block_on()`
      - Eliminates unnecessary async overhead for synchronous operations
    - **Connection**: `connect()` in `connection.rs` now uses shared global `TOKIO_RUNTIME` instead of creating a new runtime per connection
      - Prevents resource exhaustion under high connection rates
      - Eliminates expensive runtime creation overhead (each runtime spawns multiple threads)
      - Aligns with pattern used by all other operations in the codebase
  - **Impact**: Eliminates potential deadlocks, prevents BEAM scheduler blocking, ensures proper Elixir-Rust atom communication, improves error visibility, reduces overhead for replication index queries

- **Constraint Error Message Handling**
  - Enhanced constraint name extraction to support index names in error messages
  - Now correctly extracts custom index names from enhanced error format: `(index: index_name)`
  - Falls back to column name extraction for standard SQLite error messages
  - Improves `unique_constraint/3` matching with custom index names in changesets
  - Clarified documentation on composite unique constraint handling
  - Better support for complex constraint scenarios with multiple columns

- **Remote Turso Tests**
  - Reduced test database size by removing unnecessary operations
  - Improved test stability and execution reliability

## [0.7.5] - 2025-12-15

### Fixed

- **Query/Execute Routing for Batch Operations**
  - Implemented proper `query()` vs `execute()` routing in batch operations based on statement type
  - `execute_batch()` now detects SELECT and RETURNING clauses to use correct LibSQL method
  - `execute_transactional_batch()` applies same routing logic for atomicity
  - `execute_batch_native()` and `execute_transactional_batch_native()` properly route SQL batch execution
  - Prevents "Statement does not return data" errors for operations that should return rows
  - All operations with RETURNING clauses now correctly use `query()` method

- **Performance: Batch Operation Optimizations**
  - **Eliminated per-statement argument clones** in batch operations
  - Changed `batch_stmts.iter()` to `batch_stmts.into_iter()` to consume vector by value
  - Removed `args.clone()` calls for non-transactional batch.
  - Removed `args.clone()` calls for transactional batch.
  - Reduces memory allocations during batch execution for better throughput

- **Lock Coupling Reduction**
  - Dropped outer `LibSQLConn` mutex guard earlier in batch operations
  - Extract inner `Arc<Mutex<libsql::Connection>>` before entering async block
  - Only hold inner connection lock during I/O operations
  - Applied to `execute_batch()`, `execute_transactional_batch()`, `execute_batch_native()`, and `execute_transactional_batch_native()`
  - Reduces contention and deadlock surface area
  - Follows established pattern from `query_args()` function

- **Test Coverage & Documentation**
  - Enhanced `should_use_query()` test coverage for block comment handling
  - Added explicit assertion documenting known limitation: RETURNING in block comments detected as false positive (safe)
  - Documented CTE and EXPLAIN detection limitations with clear scope notes
  - Added comprehensive future improvement recommendations with priority levels and implementation sketches
  - Added performance budget note for optimization efforts

## [0.7.0] - 2025-12-09

### Added

- **Prepared Statement Caching with Reset**
  - Implemented true statement caching: statements are prepared once and reused with `.reset()` for binding cleanup
  - Changed `STMT_REGISTRY` from storing SQL text to caching actual `Arc<Mutex<Statement>>` objects
  - `prepare_statement/2` now immediately prepares statements (catches SQL errors early)
  - `query_prepared/5` uses cached statement with `stmt.reset()` call
  - `execute_prepared/6` uses cached statement with `stmt.reset()` call
  - Statement introspection functions optimized to use cached statements directly
  - Eliminates 30-50% performance overhead from repeated statement re-preparation
  - **Impact**: Significant performance improvement for prepared statement workloads (~10-15x faster for cached queries)
  - **Backward compatible**: API unchanged, behavior improved (eager validation better than deferred)

- **Statement Caching Benchmark Test**
  - Added `test/stmt_caching_benchmark_test.exs` with comprehensive caching tests
  - Verified 100 cached executions complete in ~33ms (~330µs per execution)
  - Confirmed bindings clear correctly between executions
  - Tested multiple independent cached statements
  - Demonstrated consistent performance across multiple prepared statements

- **Full Transaction Ownership & Savepoint Connection Context**
  - Implemented complete transaction-to-connection mapping with `TransactionEntry` struct
  - `TXN_REGISTRY` now tracks `conn_id` for each transaction, enabling ownership validation
  - Updated `begin_transaction/1` and `begin_transaction_with_behavior/2` to store connection owner with transaction
  - Updated `savepoint/2` NIF signature to `savepoint/3` with required `conn_id` parameter
  - All savepoint functions (`savepoint`, `release_savepoint`, `rollback_to_savepoint`) now validate transaction ownership
  - Updated `commit_or_rollback_transaction/5` to validate ownership before commit/rollback
  - Updated `declare_cursor_with_context/6` to work with transaction ownership tracking
  - Prevents cross-connection transaction manipulation by enforcing strict ownership validation
  - Returns clear error: "Transaction does not belong to this connection" on ownership violation
  - All 289 tests passing (including 18 savepoint-specific tests, 5 transaction isolation tests)
  - **Security**: Now validates actual transaction ownership, not just ID existence

- **Connection Management Features**
  - `busy_timeout/2` - Configure database busy timeout to handle locked databases (default: 5000ms)
  - `reset/1` - Reset connection state without closing the connection
  - `interrupt/1` - Interrupt long-running queries on a connection
  - All features include comprehensive tests and integration with connection lifecycle

- **PRAGMA Support (Complete SQLite Configuration)**
  - New `EctoLibSql.Pragma` module with comprehensive PRAGMA helpers (396 lines)
  - `query/2` - Execute arbitrary PRAGMA statements
  - **Foreign Keys**: `enable_foreign_keys/1`, `disable_foreign_keys/1`, `foreign_keys/1`
  - **Journal Mode**: `set_journal_mode/2`, `journal_mode/1` (supports :delete, :wal, :memory, :persist, :truncate, :off)
  - **Synchronous Level**: `set_synchronous/2`, `synchronous/1` (supports :off, :normal, :full, :extra)
  - **Cache Size**: `set_cache_size/2`, `cache_size/1` (in pages or KB with negative values)
  - **Table Introspection**: `table_info/2`, `table_list/1`
  - **User Version**: `user_version/1`, `set_user_version/2` (for schema versioning)
  - Added 19 comprehensive tests covering all PRAGMA operations

- **Native Batch Execution**
  - `execute_batch_sql/2` - Execute multiple SQL statements in a single call (non-transactional)
  - `execute_transactional_batch_sql/2` - Execute multiple SQL statements atomically in a transaction
  - Improved performance for bulk operations (migrations, seeding, etc.)
  - Added 3 comprehensive tests including atomic rollback verification

- **Advanced Replica Sync Control**
  - `get_frame_number(conn_id)` NIF - Monitor replication frame
  - `sync_until(conn_id, frame_no)` NIF - Wait for specific frame with 30-second timeout
  - `flush_replicator(conn_id)` NIF - Push pending writes with 30-second timeout
  - Elixir wrappers: `get_frame_number_for_replica()`, `sync_until_frame()`, `flush_and_get_frame()`
  - All with proper error handling, explicit None handling, and network timeouts
  - Improved error messages for timeout and non-replica scenarios

- **Max Write Replication Index**
  - `max_write_replication_index/1` - Track highest frame number from write operations
  - Enables read-your-writes consistency across replicas
  - Synchronous NIF wrapper around `db.max_write_replication_index()`
  - Use case: Ensure replica syncs to at least your write frame before reading

- **Prepared Statement Introspection**
  - `stmt_column_count/2` - Get number of columns in a prepared statement result set
  - `stmt_column_name/3` - Get column name by index (0-based)
  - `stmt_parameter_count/2` - Get number of parameters (?) in a prepared statement
  - Enables dynamic schema discovery and parameter binding validation
  - Added 21 comprehensive tests in `test/prepared_statement_test.exs`

- **Savepoint Support (Nested Transactions)**
  - `create_savepoint/2` - Create a named savepoint within a transaction
  - `release_savepoint_by_name/2` - Commit a savepoint's changes
  - `rollback_to_savepoint_by_name/2` - Rollback to a savepoint, keeping transaction active
  - Enables nested transaction-like behaviour within a single transaction
  - Perfect for error recovery and partial rollback patterns
  - Added 18 comprehensive tests in `test/savepoint_test.exs`

- **Test Suite Reorganisation**
  - Restructured tests from "missing vs implemented" to feature-based organisation
  - New feature-focused test files:
    - `test/connection_features_test.exs` (6 tests) - busy_timeout, reset, interrupt
    - `test/batch_features_test.exs` (6 tests) - batch execution
    - `test/pragma_test.exs` (19 tests) - PRAGMA operations
    - `test/statement_features_test.exs` (11 tests) - prepared statement features (mostly skipped, awaiting implementation)
    - `test/advanced_features_test.exs` (13 tests) - MVCC, cacheflush, replication, extensions, hooks (all skipped, awaiting implementation)
  - All unimplemented features properly marked with `@describetag :skip` for easy enabling as features are added

- **Comprehensive Documentation Suite**
  - `TURSO_COMPREHENSIVE_GAP_ANALYSIS.md` - Consolidated analysis of all Turso/LibSQL features
  - `IMPLEMENTATION_ROADMAP_FOCUSED.md` - Detailed implementation roadmap with prioritised phases
  - `LIBSQL_FEATURE_MATRIX_FINAL.md` - Complete feature compatibility matrix
  - `TESTING_PLAN_COMPREHENSIVE.md` - Comprehensive testing strategy and coverage plan
  - Merged multiple gap analysis documents into consolidated, authoritative sources
  - Complete source code references and Ecto integration details

### Changed

- **LibSQL 0.9.29 API Verification**
  - Verified all replication NIFs use correct libsql 0.9.29 APIs
  - `get_frame_number/1` confirmed using `db.replication_index()` (not legacy methods)
  - `sync_until/2` confirmed using `db.sync_until()`
  - `flush_replicator/1` confirmed using `db.flush_replicator()`
  - All implementations verified correct

- **Test Suite Improvements**
  - Removed duplicated tests to improve maintainability
  - Standardized test database naming conventions across all test files
  - Improved test assertions for better clarity and debugging
  - Added explicit disconnect calls to match test patterns
  - Enabled previously skipped tests for now-implemented features
  - Fixed test setup issues and race conditions
  - Performance test adjustments for slower CI machines

- **Transaction Ownership Helper Functions**
  - Added `verify_transaction_ownership/2` helper function to reduce code duplication
  - Simplified ownership validation logic across all transaction operations
  - Consolidated lock scope handling for transaction registry operations
  - Improved code maintainability and consistency

- **Replica Function API Improvements**
  - Added state-accepting overloads for replica functions for better ergonomics
  - Fixed inconsistent `flush_replicator` behavior to always use 30-second timeout
  - Improved error messages for replica operations

### Fixed

- **Security: SQL Injection Prevention**
  - Fixed potential SQL injection vulnerability in savepoint name validation
  - Added strict alphanumeric validation for savepoint identifiers
  - Prevents malicious SQL in nested transaction operations

- **Security: Prepared Statement Validation**
  - Fixed security issue in prepared statement parameter validation
  - Enhanced parameter binding checks to prevent malformed queries

- **Remote Test Stability**
  - Fixed vector operations test to properly drop existing tables before recreation
  - Removed `IF NOT EXISTS` from table creation to ensure correct schema
  - Prevents "table has no column named X" errors from stale test data

- **Upsert Operations with ON CONFLICT (Issue #25)**
  - Implemented full support for `on_conflict` options in INSERT operations
  - Added support for `on_conflict: :nothing` with conflict targets (single and composite unique indexes)
  - Added support for `on_conflict: :replace_all` for upsert operations
  - Added support for custom field replacement with `on_conflict: {fields, _, targets}`
  - Fixed composite unique index constraint handling - now correctly generates `ON CONFLICT (col1, col2) DO NOTHING/UPDATE`
  - Improved constraint name extraction from SQLite error messages to handle composite constraints
  - Added 8 comprehensive connection tests for various upsert scenarios
  - Added 154 lines of integration tests demonstrating real-world usage with composite unique indexes
  - Fixed test setup to ensure clean database state by dropping and recreating tables before each test

- **Binary ID Type System (Issue #23) - Complete Resolution**
  - Fixed `autogenerate(:binary_id)` to generate string UUIDs instead of binary UUIDs
  - Fixed `loaders(:binary_id)` to pass through string UUIDs from TEXT columns (was expecting binary)
  - Fixed `dumpers(:binary_id)` to pass through string UUIDs (was converting to binary)
  - Fixed Rust NIF to handle Elixir `Binary` type for BLOB data (was only checking `Vec<u8>`)
  - LibSQL stores `:binary_id` as TEXT, not BLOB, so string UUIDs are required throughout the pipeline
  - Prevents "Unsupported argument type" errors when inserting records with binary_id or binary fields
  - Removed unnecessary `blob_encode` wrapper - binary data now passes through directly
  - **Fixed INSERT without RETURNING clause** - Now correctly returns `rows: nil` instead of `rows: []` when no RETURNING clause is present, preventing CaseClauseError in Ecto.Adapters.SQL
  - **Fixed BLOB encoding in Rust NIF** - Binary data now returns as Elixir binaries (`<<...>>`) instead of lists (`[...]`), properly encoding BLOBs using `OwnedBinary`

- **Test Coverage Improvements**
  - Added comprehensive integration tests for `binary_id` autogeneration (6 new tests, all passing)
  - Added end-to-end tests for `:binary` (BLOB) field CRUD operations
  - Added tests for `binary_id` with associations and foreign keys
  - Total: 194 lines of new integration tests in `test/ecto_integration_test.exs`

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
