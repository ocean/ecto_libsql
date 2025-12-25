# EctoLibSql Enhancements & Future Improvements

This document consolidates all future improvements, optimisations, and enhancement suggestions from across the codebase into a single, organised reference.

## Table of Contents

1. [Critical Priority (P0) - Must-Have for Production](#critical-priority-p0---must-have-for-production)
2. [High Priority (P1) - Valuable for Most Apps](#high-priority-p1---valuable-for-most-apps)
3. [Medium Priority (P2) - Specific Use Cases](#medium-priority-p2---specific-use-cases)
4. [Low Priority (P3) - Advanced/Rare Features](#low-priority-p3---advancedrare-features)
5. [Vector & Geospatial Enhancements](#vector--geospatial-enhancements)
6. [Code Quality & Architecture Improvements](#code-quality--architecture-improvements)
7. [Testing & Documentation Enhancements](#testing--documentation-enhancements)
8. [Performance Optimisations](#performance-optimisations)
9. [Error Handling & Resilience](#error-handling--resilience)
10. [Ecto Integration Improvements](#ecto-integration-improvements)

---

## Critical Priority (P0) - Must-Have for Production

### 1. `busy_timeout()` Configuration ✅ DONE
**Status**: ✅ IMPLEMENTED (v0.6.0+)
**Impact**: CRITICAL - Without this, concurrent writes fail immediately with "database is locked" errors
**Implementation**: `set_busy_timeout/2`, `busy_timeout/2`

**Why Important**:
- Prevents immediate "database is locked" errors under concurrent load
- Essential for multi-user applications
- Standard pattern in all SQLite applications

**Desired API**:
```elixir
# At connection time
{:ok, conn} = EctoLibSql.connect(database: "local.db", busy_timeout: 5000)

# Or runtime
EctoLibSql.set_busy_timeout(state, 5000)

# In Ecto config
config :my_app, MyApp.Repo,
  adapter: Ecto.Adapters.LibSql,
  database: "local.db",
  busy_timeout: 5000  # 5 seconds (recommended default)
```

### 2. PRAGMA Query Support ✅ DONE
**Status**: ✅ IMPLEMENTED (v0.6.0+) - Basic support via `pragma_query/2`
**Impact**: HIGH - SQLite configuration is verbose and error-prone
**Implementation**: `pragma_query/2` NIF for executing PRAGMA statements

**Why Important**:
- Essential for performance tuning
- Required for foreign key enforcement (disabled by default in SQLite!)
- Needed for WAL mode configuration (better concurrency)

**Desired API**:
```elixir
# Type-safe ergonomic wrappers
EctoLibSql.Pragma.enable_foreign_keys(state)
EctoLibSql.Pragma.set_journal_mode(state, :wal)
EctoLibSql.Pragma.set_synchronous(state, :normal)
EctoLibSql.Pragma.set_cache_size(state, megabytes: 64)

# Introspection
{:ok, columns} = EctoLibSql.Pragma.table_info(state, "users")
{:ok, indexes} = EctoLibSql.Pragma.index_list(state, "users")
```

**Critical PRAGMAs to Support**:
- `foreign_keys` - FK constraint enforcement (CRITICAL - disabled by default!)
- `journal_mode` - WAL mode (much better concurrency)
- `synchronous` - Durability vs speed trade-off
- `cache_size` - Memory usage tuning
- `table_info` - Schema inspection
- `index_list` - Index inspection

### 3. `Connection.reset()` ✅ DONE
**Status**: ✅ IMPLEMENTED (v0.6.0+)
**Impact**: HIGH - Essential for proper connection pooling
**Implementation**: `reset_connection/1`, `reset/1`

**Why Important**:
- Resets connection state between checkouts from pool
- Clears temporary tables, views, triggers
- Ensures clean state for next query
- Required by `DBConnection` for proper pooling

**Desired API**:
```elixir
# Typically called by DBConnection automatically
EctoLibSql.reset_connection(state)
```

### 4. `Connection.interrupt()` ✅ DONE
**Status**: ✅ IMPLEMENTED (v0.6.0+)
**Impact**: MEDIUM - Useful for cancelling long-running queries
**Implementation**: `interrupt_connection/1`, `interrupt/1`

**Why Important**:
- Cancel long-running queries
- Useful for timeouts
- Better user experience (responsive UI)
- Operational control

**Desired API**:
```elixir
# Cancel a query running in another process
EctoLibSql.interrupt_connection(state)
```

### 5. Statement Column Metadata ✅ DONE
**Status**: ✅ IMPLEMENTED (Unreleased)
**Impact**: MEDIUM - Better developer experience and error messages
**Implementation**: `get_statement_columns/2`, `get_stmt_columns/2`, `stmt_column_count/2`, `stmt_column_name/3`

**Why Important**:
- Type introspection for dynamic queries
- Schema discovery without separate queries
- Better error messages (show column names in errors)
- Type casting hints for Ecto

**Desired API**:
```elixir
{:ok, stmt_id} = EctoLibSql.prepare(state, "SELECT * FROM users WHERE id = ?")

{:ok, columns} = EctoLibSql.get_statement_columns(stmt_id)
# Returns: [
#   %{name: "id", decl_type: "INTEGER"},
#   %{name: "name", decl_type: "TEXT"},
#   %{name: "created_at", decl_type: "TEXT"}
# ]
```

---

## High Priority (P1) - Valuable for Most Apps

### 6. `Statement.query_row()` - Single Row Query
**Status**: ❌ Missing
**Impact**: MEDIUM - Performance and ergonomics
**Estimated Effort**: 2 days

**Why Important**:
- Common pattern for `SELECT * FROM table WHERE id = ?`
- Cleaner API than `query() + take first`
- Better error handling (errors if 0 or >1 rows)
- **Optimisation**: Can stop after first row (doesn't fetch rest)

**Desired API**:
```elixir
# More efficient, clearer intent
{:ok, row} = EctoLibSql.query_one(state, stmt_id, [42])
# Returns: ["Alice", 25, "2024-01-01"]
# Errors if 0 rows or multiple rows
```

### 7. Statement `reset()` for Reuse ✅ DONE
**Status**: ✅ IMPLEMENTED (Unreleased) - Automatic reset in execute/query + explicit reset_stmt/2
**Impact**: HIGH - Significant performance issue (NOW FIXED)
**Implementation**: `reset_statement/2`, `reset_stmt/2` - statements are automatically reset before each execution

**Why Important**:
- **PERFORMANCE**: Currently we re-prepare statements on every execution
- Defeats the entire purpose of prepared statements
- Ecto caches prepared statements but we ignore the cache
- Significant performance overhead

**Current Problem**:
```rust
// lib.rs:881-888 - PERFORMANCE BUG
let stmt = conn_guard
    .prepare(&sql)  // ← Re-prepare EVERY TIME!
    .await
    .map_err(|e| rustler::Error::Term(Box::new(format!("Prepare failed: {}", e))))?;
```

**Desired Behaviour**:
```elixir
{:ok, stmt_id} = EctoLibSql.prepare(state, "INSERT INTO logs (msg) VALUES (?)")

for msg <- messages do
  EctoLibSql.execute_stmt(state, stmt_id, [msg])
  EctoLibSql.reset_stmt(stmt_id)  # ← Clear bindings, ready for reuse
end

EctoLibSql.close_stmt(stmt_id)
```

### 8. Native `execute_batch()` Implementation ✅ DONE
**Status**: ✅ IMPLEMENTED (v0.6.0+) - Both manual and native implementations available
**Impact**: MEDIUM - Performance optimisation
**Implementation**: `execute_batch_native/2`, `execute_transactional_batch_native/2`, `execute_batch_sql/2`, `execute_transactional_batch_sql/2`

**Why Important**:
- More efficient than multiple round trips
- Standard for migrations and setup scripts
- Turso optimises this internally
- Both manual sequential and native batch implementations are available

**Current Implementation**: Custom sequential execution (works but slower)

**Desired**: Use native LibSQL batch API for ~30% performance improvement

**Use Case**:
```elixir
sql = """
CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);
CREATE INDEX idx_users_name ON users(name);
INSERT INTO users VALUES (1, 'Alice'), (2, 'Bob');
"""

EctoLibSql.execute_batch(state, sql)
```

### 9. `Connection.cacheflush()` - Page Cache Control
**Status**: ❌ Missing
**Impact**: LOW - Useful for specific scenarios
**Estimated Effort**: 1 day

**Why Important**:
- Force durability before critical operations
- Testing (ensure writes are durable)
- Checkpointing control
- Memory pressure management

**Use Case**:
```elixir
# Before backup
EctoLibSql.cacheflush(state)
System.cmd("cp", ["local.db", "backup.db"])

# After bulk insert
EctoLibSql.batch_transactional(state, large_statements)
EctoLibSql.cacheflush(state)  # Ensure written to disk
```

### 10. Named Parameters Support ⚠️ PARTIAL
**Status**: ⚠️ PARTIAL - Introspection available (Unreleased), but keyword list binding not implemented
**Impact**: LOW - Ergonomics improvement
**Implemented**: `stmt_parameter_name/3` for parameter introspection
**Missing**: Keyword list → positional parameter binding in query execution

**Why Important**:
- More readable queries
- Less error-prone (no counting positions)
- Standard SQLite feature

**Current Support**:
```elixir
# Named parameters work if you use positional binding
query(conn, "SELECT * FROM users WHERE name = :name AND age = :age", ["Alice", 30])

# Parameter introspection works
{:ok, stmt_id} = prepare(state, "SELECT * FROM users WHERE id = :id")
{:ok, ":id"} = stmt_parameter_name(state, stmt_id, 1)  # Returns parameter name
```

**Not Yet Supported**:
```elixir
# Keyword list binding (requires parameter name → index mapping)
query(conn, "SELECT * FROM users WHERE name = :name AND age = :age",
  name: "Alice", age: 30)  # ← Not implemented
```

### 11. MVCC Mode Support
**Status**: ❌ Missing
**Impact**: MEDIUM - Better concurrent read performance
**Estimated Effort**: 2-3 days

**Why Important**:
- Multi-Version Concurrency Control
- Better concurrent read performance
- Non-blocking reads during writes
- Modern SQLite feature
- Turso recommended for replicas

**Desired API**:
```elixir
config :my_app, MyApp.Repo,
  adapter: Ecto.Adapters.LibSql,
  database: "local.db",
  mvcc: true
```

---

## Medium Priority (P2) - Specific Use Cases

### 12. `Statement.run()` - Execute Any Statement
**Status**: ❌ Missing
**Impact**: LOW - Flexibility
**Estimated Effort**: 2 days

**Why Important**:
- More flexible than `execute()` - works with any SQL
- Doesn't return row count (slightly more efficient)

### 13. Statement Parameter Introspection ✅ DONE
**Status**: ✅ IMPLEMENTED (Unreleased)
**Impact**: LOW - Developer experience
**Implementation**: `stmt_parameter_count/2`, `stmt_parameter_name/3`

**Why Important**:
- Dynamic query building
- Better error messages
- Validation
- Supports all three named parameter styles (`:name`, `@name`, `$name`)

### 14. `Connection.load_extension()` ✅ DONE
**Status**: ✅ IMPLEMENTED (Unreleased)
**Impact**: MEDIUM - Extensibility
**Implementation**: `enable_load_extension/2`, `load_extension/3`, `enable_extensions/2`, `load_ext/3`

**Why Important**:
- Load SQLite extensions (FTS5, JSON1, etc.)
- Custom functions
- Specialised features

**Implemented API**:
```elixir
# Enable extension loading first (disabled by default for security)
:ok = EctoLibSql.Native.enable_extensions(state, true)

# Load an extension
:ok = EctoLibSql.Native.load_ext(state, "/path/to/extension.so")

# Optional: specify custom entry point
:ok = EctoLibSql.Native.load_ext(state, "/path/to/extension.so", "sqlite3_extension_init")

# Disable extension loading after (recommended)
:ok = EctoLibSql.Native.enable_extensions(state, false)
```

**Security Note**: ⚠️ Only load extensions from trusted sources! Extensions run with full database access and can execute arbitrary code.

### 15. Replication Control (Advanced) ✅ DONE
**Status**: ✅ **FULLY IMPLEMENTED** (4 of 5 features complete as of Unreleased)

**Implemented Features**:
- ✅ `replication_index()` / `get_frame_number_for_replica()` - Get current replication frame (v0.6.0+)
- ✅ `sync_until()` / `sync_until_frame()` - Wait for specific replication point (v0.6.0+)
- ✅ `flush_replicator()` / `flush_and_get_frame()` - Force flush replicator (v0.6.0+)
- ✅ `max_write_replication_index()` / `get_max_write_frame()` - Track highest write frame (Unreleased)
- 🔄 `freeze()` / `freeze_replica()` - Convert replica to standalone (EXPLICITLY UNSUPPORTED - returns {:error, :unsupported})

**Implementation Status**:
- ✅ **Phase 1 Complete**: All monitoring functions working (v0.6.0-v0.7.0)
- ✅ **Phase 2 Complete**: `max_write_replication_index()` implemented (Unreleased)
- 🔄 **Phase 3 Deferred**: `freeze()` explicitly unsupported - needs Arc<Mutex<>> architecture refactor (documented limitation)

### 16. Hooks (Authorisation & Update)
**Status**: ❌ **NOT SUPPORTED** - Investigated, cannot be implemented due to threading limitations
**Impact**: MEDIUM - Security and real-time features
**Reason**: Rustler threading model incompatibility

**Why Not Supported**:
Both update hooks and authorizer hooks are fundamentally incompatible with Rustler's threading model:

1. **Update Hooks Problem**:
   - SQLite's update hook callback runs synchronously during INSERT/UPDATE/DELETE operations
   - Callback executes on Erlang scheduler threads (managed by BEAM)
   - Rustler's `OwnedEnv::send_and_clear()` can ONLY be called from unmanaged threads
   - Calling `send_and_clear()` from managed thread causes panic: "current thread is managed"

2. **Authorizer Hooks Problem**:
   - SQLite's authorizer callback is synchronous and expects immediate response (Allow/Deny/Ignore)
   - Would require blocking Rust thread waiting for Elixir response
   - No safe way to do synchronous Rust→Elixir→Rust calls
   - Blocking on scheduler threads can cause deadlocks

**Alternatives Provided**:

For **Change Data Capture / Real-time Updates**:
- Application-level events via Phoenix.PubSub
- Database triggers to audit log table
- Polling-based CDC with timestamps
- Phoenix.Tracker for state tracking

For **Row-Level Security / Authorization**:
- Application-level authorization checks before queries
- Database views with WHERE clauses
- Query rewriting in Ecto
- Connection-level privileges

**Implementation**: Functions return `{:error, :unsupported}` with comprehensive documentation explaining alternatives.

---

## Low Priority (P3) - Advanced/Rare Features

### 17. Custom VFS/IO
**Status**: ❌ Missing
**Impact**: LOW - Specialised use cases
**Estimated Effort**: 3 days

**Why Important**:
- Custom Virtual File System implementations
- Encryption layers
- Compression
- Testing with in-memory VFS

### 18. Statement `finalize()` & `interrupt()`
**Status**: ❌ Missing
**Impact**: LOW - Advanced control
**Estimated Effort**: 2 days

**Current**: We use simple drop for cleanup

### 19. WAL API (Write-Ahead Log - Feature-Gated)
**Status**: ❌ Missing (requires special Turso build flags)
**Impact**: LOW - Expert-level features
**Estimated Effort**: 5 days

**Why Important**:
- Advanced replication scenarios
- Custom backup solutions
- Database forensics
- Debugging

**Note**: Requires Turso feature gate, not in standard LibSQL builds

### 20. Reserved Bytes Management
**Status**: ❌ Missing
**Impact**: LOW - Advanced database tuning
**Estimated Effort**: 2 days

### 21. Advanced Builder Options
**Status**: 🟡 Partial
**Missing**:
- Custom `OpenFlags`
- `SyncProtocol` selection (V1/V2)
- Custom TLS configuration
- Thread safety flags

---

## Vector & Geospatial Enhancements

### Current Limitations
1. **2D Vector Space**: Limited to 2D (lat/long). Could extend to 3D or more dimensions
2. **Normalized Coordinates**: Works with normalized space, not actual geodetic distances
3. **Cosine Distance**: Uses vector cosine distance, not true geographic distance (haversine formula)

### Potential Enhancements
1. **Haversine Formula**: Implement actual geographic distance calculations for accuracy
2. **Higher Dimensions**: Support for more complex geospatial data (elevation, time, etc.)
3. **Index Optimization**: Add spatial indexes for performance on large datasets
4. **Batch Queries**: Use batch operations for multiple location lookups
5. **Clustering**: Find geographic clusters of locations using vector analysis

### Real-World Applications
- **Location-based services**: Find nearby restaurants, hotels, gas stations
- **Delivery optimization**: Locate nearest warehouse to customer location
- **Regional analytics**: Find closest office/branch in each region
- **Social discovery**: Find nearby users, events, or meetup groups
- **Asset tracking**: Locate nearest available equipment or resources
- **Emergency services**: Find nearest hospital, fire station, or police
- **Real estate**: Find comparable properties in similar locations
- **Market analysis**: Identify competitors in specific geographic areas

---

## Code Quality & Architecture Improvements

### 1. Reduce TXN_REGISTRY Lock Scope Around Async Calls
**Issue**: `execute_with_transaction/4`, `query_with_trx_args/5`, and savepoint NIFs run transaction.execute/query(...).await while holding the global TXN_REGISTRY mutex

**Problem**:
- Serialises all transaction operations across the registry
- Goes against "drop locks before async" guideline
- Potential contention under high load

**Solution**:
- Refactor `TransactionEntry` to hold the `Transaction` behind an `Arc<Mutex<Transaction>>`
- Look up and ownership-check under TXN_REGISTRY
- Clone the inner Arc, drop the registry lock
- Perform async work holding only the per-transaction lock

**Impact**: Better concurrency, reduced lock contention
**Effort**: 3-4 days

### 2. Complete Phase 2-5 Refactoring
**Current Status**: Phase 1 Complete (823 lines across 4 modules)
**Remaining Phases**:
- **Phase 2**: Core Operations (connection.rs, query.rs, metadata.rs)
- **Phase 3**: Advanced Features (transaction.rs, statement.rs, cursor.rs)
- **Phase 4**: Batch & Replication (batch.rs, savepoint.rs, replication.rs)
- **Phase 5**: Integration (lib.rs refactoring)

**Benefits**:
- Better code organisation
- Reduced module sizes (150-350 lines vs 2500+)
- Improved maintainability
- Clearer separation of concerns

**Effort**: 10-15 days total

### 3. Add Structured Error Types
**Current**: String-based error messages
**Desired**: Structured error types with pattern matching

**Benefits**:
- Better error handling in Elixir
- Pattern matching on error types
- More consistent error messages
- Easier to document and test

**Effort**: 5-7 days

### 4. Transaction & Concurrency Safety Enhancements
**Status**: 🟡 Partial
**Items**:

#### 4a. Transitive Validation for Prepared Statements
**Current**: Prepared statements are validated but not transitively
**Desired**: Ensure prepared statements are used only with correct connections
**Benefits**: Prevents cross-connection statement misuse, catches errors earlier
**Effort**: 3 days

#### 4b. Auditing Trail for Transaction Violations
**Current**: Violations silently fail or error
**Desired**: Log transaction ownership violations for monitoring
**Benefits**: Security monitoring, debugging, compliance tracking
**Effort**: 2 days

#### 4c. Distributed Tracing Span Context
**Current**: No span context propagation
**Desired**: Integrate with distributed tracing (OpenTelemetry)
**Benefits**: Better observability in microservices, transaction lifecycle tracking
**Effort**: 3 days

**Total Effort**: 8 days

---

## Testing & Documentation Enhancements

### 1. Comprehensive Test Coverage for New Features
**Missing Test Coverage**:
- Busy timeout functionality
- PRAGMA operations
- Connection reset behaviour
- Statement column metadata
- Named parameters
- MVCC mode
- Replication edge cases

**Effort**: 5-10 days

### 2. Performance Benchmark Tests
**Add Benchmarks For**:
- Prepared statement caching vs re-preparation
- Batch operations vs individual queries
- Cursor streaming vs full result fetch
- Transaction behaviours (deferred vs immediate vs exclusive)

**Effort**: 3-5 days

### 3. Documentation Improvements
**Enhance Documentation**:
- Add more real-world examples
- Include performance best practices
- Document error handling patterns
- Add migration guides from other databases
- Create troubleshooting guide

**Effort**: 5-7 days

### 4. Test Infrastructure Enhancements
**Status**: 🟡 Partial
**Items**:

#### 4a. Benchmarking Suite
**Current**: No performance regression testing
**Desired**: Automated benchmarking with criterion.rs
**Benefits**: Detect performance regressions, track improvements, baseline measurements
**Coverage**: Prepared statements, batch operations, cursor streaming, transaction types
**Effort**: 3 days

#### 4b. Property-Based Testing
**Current**: Limited property-based tests
**Desired**: PropCheck/StreamData for Elixir, QuickCheck for Rust
**Benefits**: Find edge cases, verify invariants, better coverage
**Effort**: 2 days

#### 4c. Mutation Testing
**Current**: Not implemented
**Desired**: Use mutation testing frameworks (stryker, mutagen)
**Benefits**: Verify test quality, identify weak tests, improve coverage
**Effort**: 2 days

#### 4d. Stress Tests for Connection Pooling
**Current**: Limited concurrent testing
**Desired**: High-concurrency stress tests for pool behavior
**Benefits**: Identify contention issues, verify pool management, test under load
**Effort**: 2 days

#### 4e. Error Recovery Scenario Testing
**Current**: Basic error handling tests
**Desired**: Comprehensive recovery testing (network failures, timeouts, corruption)
**Benefits**: Production readiness, resilience verification
**Effort**: 2 days

#### 4f. Test Coverage Reporting
**Current**: No automated coverage tracking
**Desired**: Tarpaulin (Rust), ExCoveralls (Elixir)
**Benefits**: Track coverage trends, identify untested code
**Effort**: 1 day

**Total Effort**: 12 days

### 5. Code Quality & Maintainability Enhancements
**Status**: 🟡 Partial
**Items**:

#### 5a. Guard Method Visibility Review
**Current**: Guard methods may be publicly exposed unnecessarily
**Desired**: Make guard methods private if only used internally
**Benefits**: Better encapsulation, clearer public API surface
**Effort**: 0.5 days

#### 5b. NIF Code Pattern Review
**Current**: Other NIF files may have similar patterns that need review
**Desired**: Systematic review of all NIF files for consistency
**Benefits**: Consistent code quality across modules, catch potential issues early
**Effort**: 1 day

#### 5c. NIF Logging Rules
**Current**: No linting rules to prevent eprintln! in NIF code
**Desired**: Establish clippy/linting rules to catch console output in production NIFs
**Benefits**: Prevent debugging output in production, consistent logging approach
**Implementation**: Add to `.cargo/config.toml` or `clippy.toml`:
```toml
[clippy]
disallowed-methods = [
    { path = "std::eprintln", reason = "use proper logging in NIFs" },
    { path = "std::println", reason = "use proper logging in NIFs" },
]
```
**Effort**: 0.5 days

#### 5d. SQL Keyword Extensibility
**Current**: `should_use_query()` handles SELECT and RETURNING
**Desired**: Extensible design for new SQL operations
**Benefits**: Easy to add support for new statement types, maintainable pattern
**Note**: Current implementation is already excellent, this is for future extensions
**Examples**: PRAGMA return handling, EXPLAIN queries, CTE detection
**Effort**: 1 day (if needed)

#### 5e. Guard Consumption Error Tests
**Current**: Limited integration tests for guard consumption errors
**Desired**: Comprehensive tests for MutexGuard consumption scenarios
**Benefits**: Verify error handling in edge cases, prevent regressions
**Coverage**: Poisoned mutexes, concurrent access, timeout scenarios
**Effort**: 0.5 days

**Total Effort**: 3.5 days

---

## Performance Optimisations

### 1. Prepared Statement Caching
**Current Issue**: Re-prepare statements on every execution
**Solution**: Implement proper statement caching with reset()
**Impact**: ~10-15x performance improvement for cached queries
**Effort**: 3 days

### 2. Batch Operation Optimisation
**Current**: Custom sequential implementation
**Desired**: Use native LibSQL batch API
**Impact**: ~30% performance improvement
**Effort**: 3 days

### 3. Connection Pooling Tuning
**Current**: Basic pooling
**Enhancements**:
- Dynamic pool sizing based on load
- Connection health checks
- Intelligent connection reuse
- Better error handling for exhausted pools

**Effort**: 5 days

### 4. Query Optimisation
**Add Support For**:
- Query plan analysis
- Index recommendations
- Query rewriting suggestions
- Performance warnings

**Effort**: 7 days

### 5. Performance Micro-Optimisations
**Status**: 🟢 Already analysed (future-only if profiling shows need)
**Items**:

#### 5a. SIMD Vectorization
**Current**: Single-byte comparisons in `should_use_query()`
**Desired**: SIMD instructions for multi-character checks
**Benefits**: 2-4x faster for very long SQL strings
**Complexity**: High
**Status**: Only implement if profiling identifies bottleneck
**Effort**: 3-5 days

#### 5b. Lookup Table Pre-computation
**Current**: Character-by-character comparison
**Desired**: Pre-computed lookup tables for first-byte checks
**Benefits**: ~10-20% faster SELECT detection
**Complexity**: Low
**Status**: Marginal gain, current implementation already excellent
**Effort**: 1 day

#### 5c. Lazy RETURNING Clause Check
**Current**: Full string scan for RETURNING in all statements
**Desired**: Only check RETURNING for INSERT/UPDATE/DELETE
**Benefits**: Skip RETURNING scan for SELECT, CREATE, etc.
**Complexity**: Medium
**Status**: Adds complexity without major benefit
**Effort**: 1 day

**Total Effort**: 5-7 days (investigate via profiling first)

---

## Error Handling & Resilience

### 1. Retry Logic for Transient Errors
**Add Retry For**:
- Connection timeouts
- Transient network issues
- Database locked errors (with backoff)
- Mutex contention

**Effort**: 3-5 days

### 2. Telemetry Events
**Add Telemetry For**:
- Connection establishment
- Query execution times
- Transaction lifecycle
- Error conditions
- Lock contention

**Effort**: 3 days

### 3. Circuit Breaker Pattern
**Implement**:
- Connection failure tracking
- Automatic failover to replicas
- Health check monitoring
- Graceful degradation

**Effort**: 5 days

### 4. Advanced Resilience Features
**Status**: 🟡 Partial
**Items**:

#### 4a. Connection Pooling Statistics
**Current**: Basic pool management
**Desired**: Track and expose pool metrics
**Metrics**: Wait time, checkout count, utilization, contention
**Benefits**: Better diagnostics, capacity planning, performance tuning
**Effort**: 2 days

#### 4b. Try_lock with Timeouts
**Current**: Blocking lock acquisition
**Desired**: Non-blocking lock attempts with timeouts
**Benefits**: Better responsiveness, prevent deadlocks, graceful degradation
**Use Cases**: Non-critical operations, health checks
**Effort**: 2 days

#### 4c. Supervision Tree Integration
**Current**: Basic error propagation
**Desired**: Deep integration with Elixir supervision
**Benefits**: Better crash recovery, monitoring, alerting
**Effort**: 2 days

#### 4d. Health Check Monitoring
**Current**: Basic ping functionality
**Desired**: Comprehensive health checks (latency, resource usage, connection state)
**Benefits**: Early problem detection, better failover decisions
**Effort**: 2 days

**Total Effort**: 8 days

---

## Ecto Integration Improvements

### 1. Better Ecto Adapter Integration
**Enhancements**:
- Automatic PRAGMA configuration on connection
- Better transaction behaviour mapping
- Improved error message translation
- Enhanced type mapping

**Effort**: 5 days

### 2. Phoenix Integration Examples
**Add Documentation For**:
- Context-based usage patterns
- Controller integration
- LiveView usage
- PubSub integration

**Effort**: 3 days

### 3. Migration Tooling
**Enhancements**:
- Better migration error messages
- Migration validation
- Schema diff tools
- Migration rollback improvements

**Effort**: 5 days

### 4. Connection Pool Management
**Status**: 🟡 Partial
**Items**:

#### 4a. Dynamic Pool Sizing
**Current**: Fixed pool size at startup
**Desired**: Adjust pool size based on load
**Benefits**: Better resource utilization, handles traffic spikes, reduces idle connections
**Implementation**: Monitor utilization, scale up/down based on demand
**Effort**: 3 days

#### 4b. Connection Health Checks
**Current**: Reactive failure detection
**Desired**: Proactive health monitoring
**Benefits**: Detect stale connections early, prevent cascading failures
**Implementation**: Periodic ping, liveness checks, resource monitoring
**Effort**: 2 days

#### 4c. Intelligent Connection Reuse
**Current**: Basic FIFO reuse
**Desired**: Smart connection selection based on history
**Benefits**: Better performance, avoid slow connections, faster queries
**Implementation**: Track per-connection stats, prefer "warm" connections
**Effort**: 2 days

#### 4d. Exhausted Pool Handling
**Current**: Error on pool exhaustion
**Desired**: Graceful degradation and recovery
**Benefits**: Better UX, automatic recovery, clear diagnostics
**Implementation**: Queue overflow handling, timeout management, metrics
**Effort**: 1 day

**Total Effort**: 8 days

---

## Summary

### Priority Breakdown
- **P0 (Critical)**: 5 features - Must-have for production
- **P1 (High)**: 6 features - Valuable for most applications
- **P2 (Medium)**: 6 features - Specific use cases
- **P3 (Low)**: 6 features - Advanced/rare features

### Total Estimated Effort
- **P0 Features**: ~12-15 days
- **P1 Features**: ~18-22 days
- **P2 Features**: ~15-20 days
- **P3 Features**: ~15-20 days
- **Quality/Architecture**: ~28-33 days (+8 days for transaction safety)
- **Testing/Documentation**: ~27-32 days (+12 days for test infrastructure, +3.5 days for code quality)
- **Performance**: ~20-27 days (+5-7 days for micro-optimisations)
- **Error Handling**: ~18-23 days (+8 days for advanced resilience)
- **Ecto Integration**: ~18-23 days (+8 days for pool management)

**Total**: ~175-215 days of development effort (+58.5-68.5 days from identified enhancements)

### Recommended Implementation Order
1. **P0 Critical Features** (busy_timeout, PRAGMA, reset, etc.)
2. **Performance Optimisations** (statement caching, batch operations)
3. **Error Handling & Resilience** (retry logic, telemetry)
4. **Code Quality & Maintainability** (linting rules, guard visibility, NIF pattern review)
5. **P1 High Priority Features** (query_row, named parameters, etc.)
6. **Testing & Documentation** (test infrastructure, benchmarks, coverage reporting)
7. **P2 Medium Priority Features**
8. **Ecto Integration Improvements**
9. **P3 Low Priority Features**

This prioritization ensures we address the most critical production issues first, then focus on performance and reliability, before moving to nice-to-have features and advanced functionality.