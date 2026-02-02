# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.9.0] - 2026-02-02

### Added

- **Precompiled NIF Binaries** - Users no longer need Rust, cmake, or pkg-config installed. First compile drops from 5-10 minutes to seconds using prebuilt NIF downloads for 6 targets (2 macOS, 4 Linux). Force local compilation if required with `ECTO_LIBSQL_BUILD=true`. (Thanks [@ricardo-valero](https://github.com/ricardo-valero) for [PR #70](https://github.com/ocean/ecto_libsql/pull/70)!)
- **GitHub Actions Release Workflow** - Automated NIF builds on tag push for all supported targets using `philss/rustler-precompiled-action`, with version validation against `mix.exs`

### Fixed

- **`Repo.exists?` Generates Valid SQL** - Fixed empty SELECT clause generating invalid SQL (`SELECT  FROM "users"` instead of `SELECT 1 FROM "users"`), causing syntax errors. (Thanks [@ricardo-valero](https://github.com/ricardo-valero) for [PR #69](https://github.com/ocean/ecto_libsql/pull/69)!)
- **NIF Cross-Compilation Workflow** - Fixed multiple issues preventing successful cross-compilation in GitHub Actions:
  - Fixed Cargo workspace target directory mismatch — build output goes to the workspace root `target/` directory, not the crate subdirectory
  - Moved `.cargo/config.toml` to workspace root so musl `-crt-static` rustflags are found when building from workspace root
  - Added `Cross.toml` for `RUSTLER_NIF_VERSION` environment passthrough to cross containers
  - Consolidated macOS runners to macos-15 (Apple Silicon) for both architectures

### Changed

- **Dependency Updates** - Bumped `actions/checkout` to v6, `actions/upload-artifact` to v6, updated Cargo and Credo dependencies
- **Workspace Configuration** - Added root-level `Cargo.toml` workspace with release LTO profile

## [0.8.9] - 2026-01-28

### Fixed

- **IN Clause with Ecto.Query.Tagged Structs** - Fixed issue #63 where `~w()` sigil word lists in IN clauses returned zero results due to Tagged struct wrapping. Now properly extracts list values from `Ecto.Query.Tagged` structs before generating IN clauses, enabling these patterns to work correctly.
- **SubQuery Support in IN Expressions** - Fixed SubQuery expressions being incorrectly wrapped in `JSON_EACH()`, causing invalid SQL. Now properly generates inline subqueries like `WHERE id IN (SELECT s0.id FROM table AS s0 WHERE ...)`. Fixes compatibility with libraries like Oban that use subqueries in UPDATE...WHERE patterns. (Thanks [@nadilas](https://github.com/nadilas) for PR #66 !)
- **Ecto.Query.Tagged Expression Handling** - Fixed type-cast fragments (e.g. `type(fragment(...), :integer)`) falling through to catch-all expression handler and generating incorrect parameter placeholders. Now properly handles `%Ecto.Query.Tagged{}` structs that Ecto's query planner creates from `{:type, _, [expr, type]}` AST nodes. Fixes parameter count mismatches with Hrana/Turso. (Thanks [@nadilas](https://github.com/nadilas) for PR #67 !)

## [0.8.8] - 2026-01-23

### Fixed

- **IN Clause Datatype Mismatch** - Fixed issue #63 where IN clauses with parameterised lists caused datatype mismatch errors due to automatic JSON encoding of lists
- **SQL Comment Query Detection** - Fixed Protocol.UndefinedError when queries start with SQL comments (both `--` and `/* */` styles) by properly skipping comments before detecting query type
- **RETURNING Clause for update_all/delete_all** - Added RETURNING clause generation when using update_all/delete_all with select clauses, fixing Protocol.UndefinedError with Oban job fetching

### Changed

- **Removed Unsupported Replication Tests** - Removed replication integration tests that were testing unsupported features

## [0.8.7] - 2026-01-16

### Added

- **CHECK Constraint Support** - Column-level CHECK constraints in migrations
- **R*Tree Spatial Indexing** - Full support for SQLite R*Tree virtual tables with 1D-5D indexing, validation, and comprehensive test coverage
- **ecto_sqlite3 Compatibility Test Suite** - Comprehensive tests ensuring feature parity with ecto_sqlite3
- **Type Encoding Improvements** - Automatic JSON encoding for plain maps, DateTime/Decimal parameter encoding, improved type coercion
- **Comprehensive Type Loader/Dumper Support** - Full support for encoding/decoding temporal types (DateTime, NaiveDateTime, Date, Time), Decimal, and special nil values with proper ISO 8601 formatting
- **Default Value Type Handling** - Support for Decimal, DateTime, NaiveDateTime, Date, Time, and `:null` as default values in migrations with warning logging for unsupported types
- **Connection Recovery Testing** - Test suite for connection failure scenarios and recovery patterns
- **Query Encoding Improvements** - Explicit test coverage for query parameter encoding with various data types and edge cases

### Fixed

- **DateTime Microsecond Type Loading** - Fixed `:utc_datetime_usec`, `:naive_datetime_usec`, and `:time_usec` loading from ISO 8601 strings with microsecond precision
- **Parameter Encoding** - Automatic map-to-JSON conversion, DateTime/Decimal encoding for compatibility with Oban and other libraries
- **Migration Robustness** - Handle `:serial`/`:bigserial` types, improved default value handling with warnings for unsupported types
- **JSON and RETURNING Clauses** - Fixed JSON encoding in RETURNING queries and datetime function calls
- **Test Isolation** - Comprehensive database cleanup across all test suites, per-test table clearing, improved resource management
- **DateTime Type Handling** - Fixed datetime_decode to handle timezone-aware ISO 8601 strings and nil value encoding for date/time/bool types
- **Decimal Type Handling** - Updated assertions to accept both numeric and string representations of decimal values in database queries
- **Datetime Roundtrip Preservation** - Strengthened microsecond precision preservation in datetime round-trip tests

### Changed

- **Test Suite Consolidation** - Streamlined and improved test organization with better coverage of edge cases, error handling, and concurrent operations
- **Code Quality** - Fixed Credo warnings, improved error handling patterns, removed unused variables/imports, enhanced British English consistency
- **Documentation** - Updated documentation with SQLite-specific query limitations, compatibility testing results, and guidance for type encoding edge cases

## [0.8.6] - 2026-01-07

### Added

- **R*Tree Spatial Indexing Support**
  - Full support for SQLite R*Tree virtual tables for multidimensional spatial indexing
  - **Table creation**: Use `options: [rtree: true]` in Ecto migrations
  - **Dimensions supported**: 1D to 5D (3 to 11 columns total including ID)
  - **Column structure**: First column must be `id` (integer primary key), followed by min/max coordinate pairs
  - **Validation**: Automatic validation of column count (odd numbers only), first-column requirements (must be 'id'), dimensional constraints, and incompatible table options - virtual tables reject standard table options (`:strict`, `:random_rowid`, `:without_rowid`) with clear error messages
  - **Use cases**: Geographic bounding boxes, collision detection, time-range queries, spatial indexing
  - **Migration example**:
    ```elixir
    create table(:geo_regions, options: [rtree: true]) do
      add :min_lat, :float
      add :max_lat, :float
      add :min_lng, :float
      add :max_lng, :float
    end
    ```
  - **Query patterns**: Point containment, bounding box intersection, range queries
  - **Virtual table syntax**: Generates `CREATE VIRTUAL TABLE ... USING rtree(...)` DDL
  - **Implementation**: New `create_rtree_table/3`, `validate_rtree_options!/1`, and `validate_rtree_columns!/1` helpers in `connection.ex`
  - **Comprehensive test coverage** in `test/rtree_test.exs` covering 2D/3D tables, validation, queries, and CRUD operations
  - **Documentation**: Full guide in USAGE.md with examples for geographic data, time-series, and hybrid vector+spatial search
  - **Comparison guide**: R*Tree vs Vector Search decision matrix in documentation
  - **Ecto integration**: Works with Ecto schemas using fragments for spatial queries

- **Named Parameters Execution Support**
  - Full support for SQLite named parameter syntax in prepared statements and direct execution
  - **Three SQLite syntaxes supported**: `:name`, `@name`, `$name`
  - **Transparent conversion**: Map-based named parameters automatically converted to positional arguments for internal execution
  - **Use cases**: Dynamic query building, parameter validation, better debuggability, API introspection
  - **Execution paths**: Works with prepared statements, transactions, batch operations, and cursor streaming
  - **Backward compatibility**: Existing positional parameter syntax (`?`) continues to work unchanged
  - **Implementation**: Automatic parameter binding detection and conversion in both transactional and non-transactional paths
  - **Usage examples**:
    ```elixir
    # Named parameters in prepared statements
    {:ok, stmt_id} = EctoLibSql.Native.prepare(
      state,
      "SELECT * FROM users WHERE email = :email AND status = :status"
    )
    
    # Execute with named parameters as map
    {:ok, result} = EctoLibSql.Native.query_stmt(
      state,
      stmt_id,
      %{"email" => "alice@example.com", "status" => "active"}
    )
    
    # Alternative syntaxes
    "SELECT * FROM users WHERE email = @email"
    "SELECT * FROM users WHERE email = $email"
    
    # Works with direct execution
    {:ok, _, result, state} = EctoLibSql.handle_execute(
      "INSERT INTO users (name, email) VALUES (:name, :email)",
      %{"name" => "Alice", "email" => "alice@example.com"},
      [],
      state
    )
    
    # Works with transactions
    {:ok, :begin, state} = EctoLibSql.handle_begin([], state)
    {:ok, _, _, state} = EctoLibSql.handle_execute(
      "UPDATE users SET status = :status WHERE id = :id",
      %{"status" => "inactive", "id" => 123},
      [],
      state
    )
    {:ok, _, state} = EctoLibSql.handle_commit([], state)
    ```
  - **Type handling**: All value types (strings, integers, floats, binaries, nil) properly converted
  - **Parameter validation**: Uses `stmt_parameter_name/3` introspection for validation
  - **Edge cases handled**: Empty parameter maps, missing parameters with proper error messages, mixed positional and named parameters
  - **Added comprehensive test coverage** in `test/named_parameters_execution_test.exs` covering all SQLite syntaxes, CRUD operations, transactions, batch operations, and backward compatibility

- **Query-Based UPSERT Support (on_conflict with Ecto.Query)**
  - Extended `on_conflict` support to handle query-based updates
  - Allows using keyword list syntax for dynamic update operations:
    ```elixir
    Repo.insert(changeset,
      on_conflict: [set: [name: "updated", updated_at: DateTime.utc_now()]],
      conflict_target: [:email]
    )
    ```
  - Supports `:set` and `:inc` operations in the update clause
  - Generates proper `ON CONFLICT (...) DO UPDATE SET ...` SQL
  - Requires explicit `:conflict_target` (LibSQL/SQLite requirement)
  - Implementation in `connection.ex:594-601` with `update_all_for_on_conflict/1` helper
  - 3 new tests covering query-based on_conflict with set, inc, and error cases

- **CTE (Common Table Expression) Support**
  - Full support for SQL WITH clauses in Ecto queries
  - Both simple and recursive CTEs supported
  - SQL generation in `Ecto.Adapters.LibSql.Connection` (connection.ex:843-883)
  - Rust NIF support for CTE detection in `utils.rs:should_use_query()`
  - CTEs treated as SELECT-like queries (return rows) for proper query/execute routing
  - Example usage:
    ```elixir
    cte_query = from(e in Employee, where: e.level >= 2, select: %{id: e.id, name: e.name})
    query = "high_level_employees"
            |> with_cte("high_level_employees", as: ^cte_query)
            |> select([h], h.name)
    Repo.all(query)
    ```
  - Recursive CTE example:
    ```elixir
    query = "hierarchy"
            |> with_cte("hierarchy", as: ^base_query)
            |> recursive_ctes(true)
            |> select([h], h.name)
    ```
  - 9 new CTE tests covering simple, recursive, and edge cases

- **EXPLAIN QUERY PLAN Support**
  - Full support for SQLite's `EXPLAIN QUERY PLAN` via Ecto's `Repo.explain/2` and `Repo.explain/3`
  - **Query detection**: Rust NIF `should_use_query()` now detects EXPLAIN statements for proper query/execute routing
  - **Ecto.Multi compatibility**: `explain_query/4` callback returns `{:ok, maps}` tuple format required by Ecto.Multi
  - **Output format**: Returns list of maps with `id`, `parent`, `notused`, and `detail` keys matching SQLite's output
  - **Usage examples**:
    ```elixir
    # Basic EXPLAIN QUERY PLAN
    {:ok, plan} = Repo.explain(:all, from(u in User, where: u.active == true))
    # Returns: [%{"id" => 2, "parent" => 0, "notused" => 0, "detail" => "SCAN users"}]

    # With options
    {:ok, plan} = Repo.explain(:all, query, analyze: true)

    # Direct SQL execution
    {:ok, _, result, _state} = EctoLibSql.handle_execute(
      "EXPLAIN QUERY PLAN SELECT * FROM users WHERE id = ?",
      [1],
      [],
      state
    )
    ```
  - **Implementation**: Query detection in `utils.rs:should_use_query()`, SQL generation in `connection.ex:explain_query/4`
  - **Test coverage**: 12 tests across `explain_simple_test.exs` and `explain_query_test.exs`

- **STRICT Table Option Support**
  - Added support for SQLite's STRICT table option for stronger type enforcement
  - Usage: Pass `options: [strict: true]` to `create table()` in migrations
  - Example:
    ```elixir
    create table(:users, options: [strict: true]) do
      add :name, :string
      add :age, :integer
    end
    ```
  - STRICT tables enforce column type constraints at INSERT/UPDATE time
  - Helps catch type errors early and ensures data integrity
  - Can be combined with other table options

- **Enhanced JSON and JSONB Functions**
  - Added comprehensive JSON manipulation functions for working with JSON data
  - SQL injection protection with proper parameter handling
  - Functions include `json_extract/2`, `json_type/2`, `json_valid/1`, and more
  - Consolidated JSON result handling for consistent behaviour
  - Extensive test coverage for all JSON operations

- **Cross-Connection Security Tests**
  - Added comprehensive tests for transaction isolation across connections
  - Validates that transactions from one connection cannot be accessed by another
  - Tests cover savepoints, prepared statements, and cursors
  - Ensures strict connection ownership and prevents security vulnerabilities

- **Generated/Computed Columns Documentation**
  - Added documentation for SQLite's generated column support
  - Covers both VIRTUAL and STORED generated columns
  - Examples of computed columns in migrations

### Security

- **CVE-2025-47736 Protection**
  - Comprehensive parameter validation to prevent atom table exhaustion
  - Improved parameter extraction to avoid malicious input exploitation
  - Validates all named parameters against statement introspection
  - Proper error handling for invalid or malicious parameter names
  - See [security documentation](SECURITY.md) for details

### Fixed

- **Statement Caching Improvements**
  - Replaced unbounded `persistent_term` cache with bounded ETS LRU cache
  - Prevents memory leaks from unlimited prepared statement caching
  - Configurable cache size with automatic eviction of least-recently-used entries
  - Improved cache performance and memory footprint

- **Error Handling Improvements**
  - Propagate parameter introspection errors instead of silently falling back
  - Return descriptive errors for invalid argument types in parameter normalisation
  - Improved error tuple handling in fuzz tests
  - Better error messages throughout the codebase

- **Code Quality Improvements**
  - Fixed Credo warnings (nesting, unused variables, assertions)
  - Standardised unused variable naming for consistency
  - Improved test reliability and reduced flakiness
  - Better state threading in security tests
  - Fixed binary blob round-trip handling in tests

### Changed

- **Rust UTF-8 Validation Cleanup**
  - Removed redundant UTF-8 validation comments and tautological boundary checks
  - Removed redundant `validate_utf8_sql` function (SQLite already validates UTF-8)
  - Cleaner, more maintainable codebase

## [0.8.3] - 2025-12-29

### Added

- **RANDOM ROWID Support (libSQL Extension)**
  - Added support for libSQL's RANDOM ROWID table option to generate pseudorandom rowid values instead of consecutive integers
  - **Security/Privacy Benefits**: Prevents ID enumeration attacks and leaking business metrics through sequential IDs
  - **Usage**: Pass `options: [random_rowid: true]` to `create table()` in migrations
  - **Example**:
    ```elixir
    create table(:sessions, options: [random_rowid: true]) do
      add :token, :string
      add :user_id, :integer
      timestamps()
    end
    ```
  - **Compatibility**: Works with all table configurations (single PK, composite PK, IF NOT EXISTS)
  - **Restrictions**: Mutually exclusive with WITHOUT ROWID and AUTOINCREMENT (per libSQL specification)
  - **Validation**: Early validation of mutually exclusive options with clear error messages (connection.ex:386-407)
    - Raises `ArgumentError` if RANDOM ROWID is combined with WITHOUT ROWID
    - Raises `ArgumentError` if RANDOM ROWID is combined with AUTOINCREMENT on any column
    - Prevents libSQL runtime errors by catching conflicts during migration compilation
  - SQL output: `CREATE TABLE sessions (...) RANDOM ROWID`
  - Added 7 comprehensive tests covering RANDOM ROWID with various configurations and validation scenarios
  - Documentation: See [libSQL extensions guide](https://github.com/tursodatabase/libsql/blob/main/libsql-sqlite3/doc/libsql_extensions.md#random-rowid)

- **SQLite Extension Loading Support (`enable_extensions/2`, `load_ext/3`)**
  - Load SQLite extensions dynamically from shared library files
  - **Security-first design**: Extension loading disabled by default, must be explicitly enabled
  - **Supported extensions**: FTS5 (full-text search), JSON1, R-Tree (spatial indexing), PCRE (regex), custom user-defined functions
  - Rust NIFs: `enable_load_extension/2`, `load_extension/3` in `src/connection.rs`
  - Elixir wrappers: `EctoLibSql.Native.enable_extensions/2`, `EctoLibSql.Native.load_ext/3`
  - **API workflow**: Enable extension loading → Load extension(s) → Disable extension loading (recommended)
  - **Entry point support**: Optional custom entry point function name parameter
  - **Platform support**: .so (Linux), .dylib (macOS), .dll (Windows)
  - **Use cases**: Full-text search (FTS5), JSON functions, spatial data (R-Tree), regex matching, custom SQL functions
  - **Security warnings**: Only load extensions from trusted sources - extensions have full database access
  - Comprehensive documentation with security warnings and common extension examples

- **Statement Parameter Name Introspection (`stmt_parameter_name/3`)**
  - Retrieve parameter names from prepared statements with named parameters
  - **Supports all SQLite named parameter styles**: `:name`, `@name`, `$name`
  - **Use cases**: Dynamic query building, parameter validation, better debugging, API introspection
  - Rust NIF: `statement_parameter_name()` in `src/statement.rs`
  - Elixir wrapper: `EctoLibSql.Native.stmt_parameter_name/3`
  - Returns `{:ok, "name"}` for named parameters (prefix included) or `{:ok, nil}` for positional `?` placeholders
  - **Note**: Uses 1-based parameter indexing (first parameter is index 1) following SQLite convention
  - Added 5 comprehensive tests covering all three named parameter styles, positional parameters, and mixed parameter scenarios
  - Complements existing `stmt_parameter_count/2` for complete parameter introspection

- **Comprehensive Statement Introspection Test Coverage**
  - Added 18 edge case tests for prepared statement introspection features (13 existing + 5 parameter_name tests)
  - **Parameter introspection edge cases**: 0 parameters, 20+ parameters, UPDATE statements, complex nested queries, named parameter introspection
  - **Column introspection edge cases**: SELECT *, INSERT/UPDATE/DELETE without RETURNING (0 columns), aggregate functions, JOINs, subqueries, computed expressions
  - Improved test coverage for `stmt_parameter_count/2`, `stmt_parameter_name/3`, `stmt_column_count/2`, and `stmt_column_name/3`
  - All tests verify correct behaviour for simple queries, complex JOINs, aggregates, and edge cases
  - Tests ensure proper handling of aliased columns, expressions, multi-table queries, and all three named parameter styles
  - Location: `test/statement_features_test.exs` - added 180+ lines of comprehensive edge case tests

- **Statement Reset (`reset_stmt/2`)**
  - Explicitly reset prepared statements to initial state for efficient reuse
  - **Performance improvement**: 10-15x faster than re-preparing the same SQL string
  - Enables optimal statement reuse pattern: prepare once, execute many times with reset between executions
  - Rust NIF: `reset_statement()` in `src/statement.rs`
  - Elixir wrapper: `EctoLibSql.Native.reset_stmt/2`
  - Added 3 comprehensive tests covering explicit reset, multiple resets, and error handling
  - Usage: `EctoLibSql.Native.reset_stmt(state, stmt_id)` returns `:ok` or `{:error, reason}`

- **Statement Column Metadata (`get_stmt_columns/2`)**
  - Retrieve full column metadata from prepared statements
  - Returns column name, origin name, and declared type for all columns
  - **Use cases**: Type introspection for dynamic queries, schema discovery, better error messages, type casting hints
  - Rust NIF: `get_statement_columns()` in `src/statement.rs`
  - Elixir wrapper: `EctoLibSql.Native.get_stmt_columns/2`
  - Returns `{:ok, [{name, origin_name, decl_type}]}` tuples for each column
  - Added 4 comprehensive tests covering basic metadata, aliased columns, expressions, and error handling
  - Supports complex queries with aliases, joins, and aggregate functions

- **Remote Encryption Support for Turso Encrypted Databases**
  - Added support for Turso cloud encrypted databases via `remote_encryption_key` connection option
  - Complements existing local encryption (`encryption_key`) for at-rest database file encryption
  - **Encryption types**:
    - **Local encryption**: AES-256-CBC for local SQLite files (existing feature)
    - **Remote encryption**: Base64-encoded encryption key sent with each request to Turso (new feature)
  - **Connection modes supported**: Remote and Remote Replica
  - **Usage**: `remote_encryption_key: "base64-encoded-key"` in connection options
  - Remote replica mode can use both local and remote encryption simultaneously for end-to-end encryption
  - Updated Rust NIF: Enhanced `connect()` in `src/connection.rs` with `EncryptionContext` and `EncryptionKey::Base64Encoded`
  - Updated documentation in README.md with examples for all encryption scenarios
  - See [Turso Encryption Documentation](https://docs.turso.tech/cloud/encryption) for key generation and requirements

- **Comprehensive Elixir Code Quality Tooling**
  - Added **Credo** for static code analysis with strict configuration (`.credo.exs`)
  - Added **Dialyxir** for type checking with proper ignore patterns (`.dialyzer_ignore.exs`)
  - Added **Sobelow** security scanner for vulnerability detection
  - All three tools integrated into GitHub CI pipeline for automated quality checks

- **Property-Based Fuzz Testing (Elixir)**
  - New `test/fuzz_test.exs` with comprehensive property-based tests using StreamData
  - **SQL injection prevention tests** - Verifies parameters are safely escaped
  - **Transaction behaviour fuzzing** - Tests `:deferred`, `:immediate`, `:exclusive` modes
  - **Prepared statement fuzzing** - Tests various parameter types (integers, strings, floats)
  - **Edge case numeric tests** - Tests 64-bit integer bounds and special float values
  - **Binary/BLOB data handling** - Tests arbitrary binary data and round-trip integrity
  - **Savepoint name validation** - Tests SQL injection prevention in nested transactions
  - **Connection ID handling** - Tests graceful handling of invalid connection IDs

- **Ecto SQL Adapter Compatibility Tests**
  - `test/ecto_sql_compatibility_test.exs` - Core SQL compatibility tests
  - `test/ecto_sql_transaction_compat_test.exs` - Transaction compatibility tests
  - `test/ecto_stream_compat_test.exs` - Streaming compatibility tests
  - Ported key tests from Ecto.Adapters.SQL test suite to verify compatibility

- **Rust Fuzz Testing Infrastructure**
  - Added `cargo-fuzz` based fuzzing in `native/ecto_libsql/fuzz/`
  - Fuzz targets: `fuzz_detect_query_type`, `fuzz_should_use_query`, `fuzz_sql_structured`
  - CI integration runs each fuzz target for 30 seconds per build
  - Documentation in `native/ecto_libsql/FUZZING.md`

- **Rust Property-Based Testing**
  - Added `proptest` crate for property-based testing
  - New `tests/proptest_tests.rs` with structured SQL generation tests
  - Tests query type detection with generated SQL patterns

- **License and Security Advisory Checking**
  - Added `cargo-deny` configuration (`deny.toml`) for dependency auditing
  - Checks for license compliance, security advisories, duplicate dependencies
  - Integrated into CI pipeline

- **SQLite Hook Investigation (Documented as Unsupported)**
  - Researched SQLite update hooks and authorizer hooks for CDC and RLS
  - Added `src/hooks.rs` with explicit `:unsupported` returns
  - Documented Rustler threading limitations preventing implementation
  - Added `test/hooks_test.exs` verifying unsupported behaviour
  - Comprehensive documentation of alternative approaches in CHANGELOG

### Changed

- **Elixir Code Quality Improvements**
  - **Eliminated duplicate code** in `batch/2` and `batch_transactional/2` functions
    - Extracted common `parse_batch_results/1` helper function
  - **Improved unused variable naming consistency** across all test files
    - Changed `{:ok, _, _, state}` patterns to `{:ok, _query, _result, state}`
    - Changed `{:error, _}` patterns to `{:error, _reason}`
  - **Added typespecs** to key public functions:
    - `sync/1`, `begin/2`, `commit/1`, `rollback/1` in `EctoLibSql.Native`
    - `batch/2`, `batch_transactional/2` in `EctoLibSql.Native`
    - `query/2`, `enable_foreign_keys/1` in `EctoLibSql.Pragma`
  - **Fixed Dialyzer ignore file format** - Changed from tuples to regex list

- **Rust Code Modernisation**
  - Replaced `lazy_static!` with `std::sync::LazyLock` (Rust 1.80+ feature)
  - Added stricter Clippy lints: `clippy::unwrap_used`, `clippy::expect_used`
  - Fixed all Clippy warnings across the codebase
  - Improved error handling patterns throughout

- **CI Pipeline Enhancements**
  - Added Credo and Sobelow checks to `elixir-tests-latest` job
  - Added Rust fuzz testing job with 30-second per-target runs
  - Added `cargo-deny` license and advisory checking
  - Improved caching for faster builds

### Fixed

- **Security: SQL Injection Prevention in Pragma Module**
  - Added `valid_identifier?/1` function to sanitise table names in `table_info/2`
  - Prevents potential SQL injection via malicious table names
  - Returns `{:error, {:invalid_identifier, name}}` for invalid identifiers

- **Dialyzer Type Errors**
  - Fixed `disconnect/2` spec type mismatch with DBConnection behaviour
  - Changed first argument type from `Keyword.t()` to `term()`

- **Fuzz Test Stability**
  - Fixed savepoint fuzz tests to handle transaction conflicts gracefully
  - Fixed handling of non-UTF8 binary data in NIF calls
  - Added proper try/rescue blocks for ArgumentError in fuzz tests

### Clarifications

- **ALTER TABLE ALTER COLUMN Support (Already Implemented)**
  - **Fully supported** since v0.6.0 - libSQL's ALTER COLUMN extension for modifying column attributes
  - **Capabilities**: Modify type affinity, NOT NULL, CHECK, DEFAULT, and REFERENCES constraints
  - **Usage**: Use `:modify` in migrations as with other Ecto adapters
  - **Example**:
    ```elixir
    alter table(:users) do
      modify :age, :string, default: "0"  # Change type and default
      modify :email, :string, null: false # Add NOT NULL constraint
    end
    ```
  - **Important**: Changes only apply to new/updated rows; existing data is not revalidated
  - **Implementation**: `lib/ecto/adapters/libsql/connection.ex:213-219` handles `:modify` changes
  - SQL output: `ALTER TABLE users ALTER COLUMN age TO age TEXT DEFAULT '0'`
  - This is a **libSQL extension** beyond standard SQLite (SQLite does not support ALTER COLUMN)

### Investigated but Not Supported

- **Hooks Investigation**: Researched implementation of SQLite hooks (update hooks and authorizer hooks) for CDC and row-level security
  - **Update Hooks (CDC)**: Cannot be implemented due to Rustler threading limitations
    - SQLite's update hook runs on managed BEAM threads
    - Rustler's `OwnedEnv::send_and_clear()` can ONLY be called from unmanaged threads
    - Would cause panic: "send_and_clear: current thread is managed"
  - **Authorizer Hooks (RLS)**: Cannot be implemented due to synchronous callback requirements
    - Requires immediate synchronous response (Allow/Deny/Ignore)
    - No safe way to block waiting for Elixir response from scheduler thread
    - Would risk deadlocks with scheduler thread blocking
  - **Result**: Both `add_update_hook/2`, `remove_update_hook/1`, and `add_authorizer/2` return `{:error, :unsupported}`
  - **Alternatives provided**: Comprehensive documentation of alternative approaches:
    - For CDC: Application-level events, database triggers, polling, Phoenix.Tracker
    - For RLS: Application-level auth, database views, query rewriting, connection-level privileges
  - See Rustler issue: https://github.com/rusterlium/rustler/issues/293

## [0.8.1] - 2025-12-18

### Fixed

- **Constraint Error Handling: Index Name Reconstruction (Issue #34)**
  - Improved constraint name extraction to reconstruct full index names from SQLite error messages
  - Now follows Ecto's naming convention: `table_column1_column2_index`
  - **Single-column constraints**: `"UNIQUE constraint failed: users.email"` → `"users_email_index"` (previously just `"email"`)
  - **Multi-column constraints**: `"UNIQUE constraint failed: users.slug, users.parent_slug"` → `"users_slug_parent_slug_index"`
  - **Backtick handling**: Properly strips trailing backticks appended by libSQL to error messages
  - **Enhanced error messages**: Preserves custom index names from enhanced format `(index: custom_index_name)`
  - **NOT NULL constraints**: Reconstructs index names following same convention
  - Enables accurate `unique_constraint/3` and `check_constraint/3` matching with custom index names in Ecto changesets
  - Added comprehensive test coverage for all constraint scenarios (4 new tests)

## [0.8.0] - 2025-12-17

### Changed

- **Major Rust Code Refactoring (Modularisation)**
  - Split monolithic `lib.rs` (2,302 lines) into 13 focussed, single-responsibility modules
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
  - **Performance Optimisations**:
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

- **Performance: Batch Operation Optimisations**
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
  - Added performance budget note for optimisation efforts

## [0.7.0] - 2025-12-09

### Added

- **Prepared Statement Caching with Reset**
  - Implemented true statement caching: statements are prepared once and reused with `.reset()` for binding cleanup
  - Changed `STMT_REGISTRY` from storing SQL text to caching actual `Arc<Mutex<Statement>>` objects
  - `prepare_statement/2` now immediately prepares statements (catches SQL errors early)
  - `query_prepared/5` uses cached statement with `stmt.reset()` call
  - `execute_prepared/6` uses cached statement with `stmt.reset()` call
  - Statement introspection functions optimised to use cached statements directly
  - Eliminates 30-50% performance overhead from repeated statement re-preparation
  - **Impact**: Significant performance improvement for prepared statement workloads (~10-15x faster for cached queries)
  - **Backward compatible**: API unchanged, behaviour improved (eager validation better than deferred)

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
  - Standardised test database naming conventions across all test files
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
  - Fixed inconsistent `flush_replicator` behaviour to always use 30-second timeout
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
