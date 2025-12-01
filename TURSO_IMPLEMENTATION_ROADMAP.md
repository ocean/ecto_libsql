# Turso Feature Implementation Roadmap

**Status**: Planning Phase
**Version**: 1.0.0
**Last Updated**: 2025-12-01

This document provides a step-by-step implementation guide for adding missing Turso features to ecto_libsql. Each section includes implementation details, code snippets, testing requirements, and estimated effort.

## Quick Reference

| Feature | Priority | Effort | Status | Tests | Docs |
|---------|----------|--------|--------|-------|------|
| busy_timeout | P0 | 2-3 days | ⬜ Planned | ⬜ | ⬜ |
| PRAGMA support | P0 | 3-4 days | ⬜ Planned | ⬜ | ⬜ |
| Statement columns | P0 | 2 days | ⬜ Planned | ⬜ | ⬜ |
| query_row | P1 | 2 days | ⬜ Planned | ⬜ | ⬜ |
| execute_batch native | P1 | 3 days | ⬜ Planned | ⬜ | ⬜ |
| cacheflush | P1 | 1 day | ⬜ Planned | ⬜ | ⬜ |
| Statement reset | P1 | 2 days | ⬜ Planned | ⬜ | ⬜ |
| MVCC mode | P1 | 2-3 days | ⬜ Planned | ⬜ | ⬜ |
| JSON helpers | P2 | 3-4 days | ⬜ Planned | ⬜ | ⬜ |
| UUID functions | P2 | 2-3 days | ⬜ Planned | ⬜ | ⬜ |
| Custom VFS | P2 | 3-4 days | ⬜ Planned | ⬜ | ⬜ |
| Vector enhancements | P2 | 3-4 days | ⬜ Planned | ⬜ | ⬜ |
| Connection stats | P2 | 2-3 days | ⬜ Planned | ⬜ | ⬜ |
| Query profiling | P2 | 2-3 days | ⬜ Planned | ⬜ | ⬜ |
| WAL API | P3 | 5-7 days | ⬜ Planned | ⬜ | ⬜ |

**Legend**: ⬜ Planned | 🟡 In Progress | ✅ Complete | ❌ Blocked

---

## Phase 1: Critical Features (v0.6.0)

### Feature 1: busy_timeout() Configuration

**Priority**: P0 (Critical)
**Effort**: 2-3 days
**Dependencies**: None

#### Implementation Steps

##### 1. Rust NIF Function

Add to `native/ecto_libsql/src/lib.rs`:

```rust
#[rustler::nif(schedule = "DirtyIo")]
pub fn set_busy_timeout(conn_id: &str, timeout_ms: u64) -> NifResult<bool> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "set_busy_timeout conn_map")?;

    if let Some(client) = conn_map.get(conn_id) {
        let client = client.clone();
        drop(conn_map); // Release lock before async

        let result = TOKIO_RUNTIME.block_on(async {
            let client_guard = safe_lock_arc(&client, "set_busy_timeout client")
                .map_err(|e| format!("{:?}", e))?;
            let conn_guard = safe_lock_arc(&client_guard.client, "set_busy_timeout conn")
                .map_err(|e| format!("{:?}", e))?;

            let duration = Duration::from_millis(timeout_ms);
            conn_guard.busy_timeout(duration)
                .await
                .map_err(|e| format!("Failed to set busy_timeout: {}", e))
        });

        match result {
            Ok(_) => Ok(true),
            Err(e) => Err(rustler::Error::Term(Box::new(e)))
        }
    } else {
        Err(rustler::Error::Term(Box::new("Connection not found")))
    }
}
```

##### 2. Export in rustler::init!

Add to the NIF exports in `lib.rs`:

```rust
rustler::init!(
    "Elixir.EctoLibSql.Native",
    [
        // ... existing functions ...
        set_busy_timeout,
    ]
)
```

##### 3. Elixir Wrapper

Add to `lib/ecto_libsql/native.ex`:

```elixir
@doc false
def set_busy_timeout(_conn, _timeout_ms), do: :erlang.nif_error(:nif_not_loaded)

@doc """
Set the busy timeout for the connection.

When the database is locked, SQLite will wait up to this timeout before
returning SQLITE_BUSY. Default is 0 (no waiting).

## Parameters
  - state: Connection state
  - timeout_ms: Timeout in milliseconds

## Example
    {:ok, state} = EctoLibSql.connect(database: "local.db")
    {:ok, true} = EctoLibSql.Native.set_busy_timeout(state, 5000)
"""
def set_busy_timeout(%EctoLibSql.State{conn_id: conn_id}, timeout_ms)
    when is_integer(timeout_ms) and timeout_ms >= 0 do
  case set_busy_timeout(conn_id, timeout_ms) do
    true -> {:ok, true}
    {:error, reason} -> {:error, reason}
  end
end
```

##### 4. Connection Option Support

Update `lib/ecto_libsql.ex` connect function:

```elixir
def connect(opts) do
  case EctoLibSql.Native.connect(opts, EctoLibSql.State.detect_mode(opts)) do
    conn_id when is_binary(conn_id) ->
      state = %EctoLibSql.State{
        conn_id: conn_id,
        mode: EctoLibSql.State.detect_mode(opts),
        sync: EctoLibSql.State.detect_sync(opts)
      }

      # Set busy timeout if provided
      state = case Keyword.get(opts, :busy_timeout) do
        nil -> state
        timeout when is_integer(timeout) ->
          {:ok, _} = EctoLibSql.Native.set_busy_timeout(state, timeout)
          state
      end

      {:ok, state}

    {:error, _} = err -> err
    other -> {:error, {:unexpected_response, other}}
  end
end
```

#### Testing Checklist

- [ ] Unit test: Set timeout to various values (0, 1000, 5000)
- [ ] Unit test: Error on invalid connection ID
- [ ] Integration test: Verify timeout prevents immediate "locked" errors
- [ ] Integration test: Test concurrent writes with/without timeout
- [ ] Integration test: Test timeout in connection options
- [ ] Performance test: Measure wait times with different timeouts

#### Documentation

- [ ] Add to `AGENTS.md` with usage examples
- [ ] Add to `CHANGELOG.md`
- [ ] Add inline docs to Elixir functions
- [ ] Add migration guide note

---

### Feature 2: PRAGMA Query Support

**Priority**: P0 (Critical)
**Effort**: 3-4 days
**Dependencies**: None

#### Implementation Steps

##### 1. Rust NIF Function

Add to `native/ecto_libsql/src/lib.rs`:

```rust
#[rustler::nif(schedule = "DirtyIo")]
pub fn pragma_query<'a>(
    env: Env<'a>,
    conn_id: &str,
    pragma_name: &str,
    value: Option<String>,
) -> NifResult<Term<'a>> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "pragma_query conn_map")?;

    if let Some(client) = conn_map.get(conn_id) {
        let client = client.clone();
        drop(conn_map);

        let pragma_sql = if let Some(val) = value {
            format!("PRAGMA {} = {}", pragma_name, val)
        } else {
            format!("PRAGMA {}", pragma_name)
        };

        let result = TOKIO_RUNTIME.block_on(async {
            let client_guard = safe_lock_arc(&client, "pragma_query client")
                .map_err(|e| format!("{:?}", e))?;
            let conn_guard = safe_lock_arc(&client_guard.client, "pragma_query conn")
                .map_err(|e| format!("{:?}", e))?;

            let rows = conn_guard.query(&pragma_sql, ())
                .await
                .map_err(|e| format!("PRAGMA query failed: {}", e))?;

            collect_rows(env, rows).await
                .map_err(|e| format!("{:?}", e))
        });

        match result {
            Ok(term) => Ok(term),
            Err(e) => Err(rustler::Error::Term(Box::new(e)))
        }
    } else {
        Err(rustler::Error::Term(Box::new("Connection not found")))
    }
}
```

##### 2. Elixir Wrapper

Add to `lib/ecto_libsql/native.ex`:

```elixir
@doc false
def pragma_query(_conn, _pragma_name, _value), do: :erlang.nif_error(:nif_not_loaded)

@doc """
Execute a PRAGMA query.

## Parameters
  - state: Connection state
  - pragma_name: Name of the PRAGMA
  - value: Optional value to set (if nil, queries current value)

## Example
    # Get current value
    {:ok, result} = EctoLibSql.Native.pragma_query(state, "journal_mode", nil)

    # Set value
    {:ok, result} = EctoLibSql.Native.pragma_query(state, "journal_mode", "WAL")
"""
def pragma_query(%EctoLibSql.State{conn_id: conn_id}, pragma_name, value \\ nil) do
  case pragma_query(conn_id, pragma_name, value) do
    %{"columns" => _columns, "rows" => rows} ->
      {:ok, parse_pragma_result(pragma_name, rows)}
    {:error, reason} ->
      {:error, reason}
  end
end

defp parse_pragma_result("table_info", rows) do
  # Convert to list of maps with column info
  Enum.map(rows, fn [cid, name, type, notnull, dflt_value, pk] ->
    %{
      cid: cid,
      name: name,
      type: type,
      notnull: notnull == 1,
      default_value: dflt_value,
      primary_key: pk == 1
    }
  end)
end

defp parse_pragma_result(_pragma, [[value]]) do
  # Single value result
  value
end

defp parse_pragma_result(_pragma, rows) do
  # Multiple rows or complex result
  rows
end
```

##### 3. High-Level PRAGMA Helpers

Create new file `lib/ecto_libsql/pragma.ex`:

```elixir
defmodule EctoLibSql.Pragma do
  @moduledoc """
  High-level helpers for SQLite PRAGMA operations.

  Provides type-safe, ergonomic wrappers around common PRAGMA operations.
  """

  @doc "Enable foreign key constraint enforcement"
  def enable_foreign_keys(state) do
    EctoLibSql.Native.pragma_query(state, "foreign_keys", "ON")
  end

  @doc "Disable foreign key constraint enforcement"
  def disable_foreign_keys(state) do
    EctoLibSql.Native.pragma_query(state, "foreign_keys", "OFF")
  end

  @doc "Check if foreign keys are enabled"
  def foreign_keys_enabled?(state) do
    case EctoLibSql.Native.pragma_query(state, "foreign_keys", nil) do
      {:ok, "1"} -> {:ok, true}
      {:ok, "0"} -> {:ok, false}
      {:ok, 1} -> {:ok, true}
      {:ok, 0} -> {:ok, false}
      error -> error
    end
  end

  @doc "Set journal mode (DELETE, TRUNCATE, PERSIST, MEMORY, WAL, OFF)"
  def set_journal_mode(state, mode) when mode in [:delete, :truncate, :persist, :memory, :wal, :off] do
    mode_str = mode |> Atom.to_string() |> String.upcase()
    EctoLibSql.Native.pragma_query(state, "journal_mode", mode_str)
  end

  @doc "Set WAL mode (shorthand for set_journal_mode(state, :wal))"
  def set_wal_mode(state) do
    set_journal_mode(state, :wal)
  end

  @doc "Get current journal mode"
  def get_journal_mode(state) do
    case EctoLibSql.Native.pragma_query(state, "journal_mode", nil) do
      {:ok, mode} when is_binary(mode) ->
        {:ok, mode |> String.downcase() |> String.to_atom()}
      error ->
        error
    end
  end

  @doc "Set cache size in KB (negative) or pages (positive)"
  def set_cache_size(state, opts) do
    size = cond do
      kb = Keyword.get(opts, :kilobytes) -> -kb
      mb = Keyword.get(opts, :megabytes) -> -(mb * 1024)
      pages = Keyword.get(opts, :pages) -> pages
      true -> raise ArgumentError, "Must specify :kilobytes, :megabytes, or :pages"
    end

    EctoLibSql.Native.pragma_query(state, "cache_size", to_string(size))
  end

  @doc "Get cache size"
  def get_cache_size(state) do
    EctoLibSql.Native.pragma_query(state, "cache_size", nil)
  end

  @doc "Set synchronous mode (OFF, NORMAL, FULL, EXTRA)"
  def set_synchronous(state, mode) when mode in [:off, :normal, :full, :extra] do
    mode_str = mode |> Atom.to_string() |> String.upcase()
    EctoLibSql.Native.pragma_query(state, "synchronous", mode_str)
  end

  @doc "Get table information (columns, types, constraints)"
  def table_info(state, table_name) do
    EctoLibSql.Native.pragma_query(state, "table_info", table_name)
  end

  @doc "List all tables in database"
  def table_list(state) do
    EctoLibSql.Native.pragma_query(state, "table_list", nil)
  end

  @doc "List indexes on a table"
  def index_list(state, table_name) do
    EctoLibSql.Native.pragma_query(state, "index_list", table_name)
  end

  @doc "Get database encoding"
  def get_encoding(state) do
    EctoLibSql.Native.pragma_query(state, "encoding", nil)
  end

  @doc "Get page size"
  def get_page_size(state) do
    EctoLibSql.Native.pragma_query(state, "page_size", nil)
  end

  @doc "Set page size (must be power of 2 between 512 and 65536)"
  def set_page_size(state, size) when size in [512, 1024, 2048, 4096, 8192, 16384, 32768, 65536] do
    EctoLibSql.Native.pragma_query(state, "page_size", to_string(size))
  end
end
```

#### Testing Checklist

- [ ] Unit test: Query each common PRAGMA
- [ ] Unit test: Set each common PRAGMA
- [ ] Integration test: table_info returns correct schema
- [ ] Integration test: Foreign keys work when enabled
- [ ] Integration test: WAL mode persists
- [ ] Integration test: Cache size affects performance
- [ ] Test all helper functions in Pragma module

#### Documentation

- [ ] Add `lib/ecto_libsql/pragma.ex` to documentation
- [ ] Document all PRAGMA helpers with examples
- [ ] Add PRAGMA usage section to AGENTS.md
- [ ] Update CHANGELOG.md

---

### Feature 3: Statement columns() Metadata

**Priority**: P0 (Critical)
**Effort**: 2 days
**Dependencies**: None

#### Implementation Steps

##### 1. Enhance Statement Registry

Update `STMT_REGISTRY` in `lib.rs` to store prepared statements:

```rust
use lazy_static::lazy_static;
use libsql::Statement;

lazy_static! {
    // Change from (conn_id, sql) to (conn_id, sql, Option<Statement>)
    static ref STMT_REGISTRY: Mutex<HashMap<String, (String, String, Option<Arc<Mutex<Statement>>>)>> =
        Mutex::new(HashMap::new());
}
```

Wait, this won't work because `Statement` isn't `Send + Sync`. Let me reconsider...

Actually, we need to store statement metadata separately. Better approach:

##### 1. Rust NIF Function

```rust
#[rustler::nif(schedule = "DirtyIo")]
pub fn get_statement_columns<'a>(
    env: Env<'a>,
    conn_id: &str,
    stmt_id: &str,
) -> NifResult<Term<'a>> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "get_statement_columns conn_map")?;
    let stmt_registry = safe_lock(&STMT_REGISTRY, "get_statement_columns stmt_registry")?;

    if conn_map.get(conn_id).is_none() {
        return Err(rustler::Error::Term(Box::new("Invalid connection ID")));
    }

    let client = conn_map
        .get(conn_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Connection not found")))?
        .clone();

    let (_stored_conn_id, sql) = stmt_registry
        .get(stmt_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Statement not found")))?;

    let sql = sql.clone();
    drop(stmt_registry);
    drop(conn_map);

    let columns = TOKIO_RUNTIME.block_on(async {
        let client_guard = safe_lock_arc(&client, "get_statement_columns client")?;
        let conn_guard = safe_lock_arc(&client_guard.client, "get_statement_columns conn")?;

        let stmt = conn_guard
            .prepare(&sql)
            .await
            .map_err(|e| rustler::Error::Term(Box::new(format!("Prepare failed: {}", e))))?;

        let columns = stmt.columns();

        // Convert to Elixir-friendly format
        let column_info: Vec<(String, Option<String>)> = columns
            .iter()
            .map(|col| {
                (col.name().to_string(), col.decl_type().map(|t| t.to_string()))
            })
            .collect();

        Ok::<_, rustler::Error>(column_info)
    })?;

    Ok(columns.encode(env))
}
```

##### 2. Elixir Wrapper

```elixir
@doc false
def get_statement_columns(_conn, _stmt_id), do: :erlang.nif_error(:nif_not_loaded)

@doc """
Get column metadata from a prepared statement.

Returns information about the columns that will be returned by the statement,
including column names and declared types.

## Parameters
  - conn_id: Connection ID (or state)
  - stmt_id: Statement ID from prepare/2

## Returns
  - `{:ok, columns}` where columns is a list of maps with :name and :decl_type keys
  - `{:error, reason}` on failure

## Example
    {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "SELECT id, name, age FROM users")
    {:ok, columns} = EctoLibSql.Native.get_statement_columns(state, stmt_id)
    # Returns: [
    #   %{name: "id", decl_type: "INTEGER"},
    #   %{name: "name", decl_type: "TEXT"},
    #   %{name: "age", decl_type: "INTEGER"}
    # ]
"""
def get_statement_columns(%EctoLibSql.State{conn_id: conn_id}, stmt_id) do
  case get_statement_columns(conn_id, stmt_id) do
    columns when is_list(columns) ->
      parsed = Enum.map(columns, fn {name, decl_type} ->
        %{name: name, decl_type: decl_type}
      end)
      {:ok, parsed}

    {:error, reason} ->
      {:error, reason}
  end
end
```

#### Testing Checklist

- [ ] Unit test: Get columns from simple SELECT
- [ ] Unit test: Get columns from complex JOIN
- [ ] Unit test: Get columns with aliases
- [ ] Integration test: Column types match table schema
- [ ] Error test: Invalid statement ID
- [ ] Error test: Invalid connection ID

#### Documentation

- [ ] Add examples to Native module docs
- [ ] Add section to AGENTS.md on statement introspection
- [ ] Update CHANGELOG.md

---

### Feature 4: query_row() Single Row Query

**Priority**: P1 (High)
**Effort**: 2 days
**Dependencies**: None

#### Implementation Steps

##### 1. Rust NIF Function

```rust
#[rustler::nif(schedule = "DirtyIo")]
pub fn query_row<'a>(
    env: Env<'a>,
    conn_id: &str,
    stmt_id: &str,
    args: Vec<Term<'a>>,
) -> NifResult<Term<'a>> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "query_row conn_map")?;
    let stmt_registry = safe_lock(&STMT_REGISTRY, "query_row stmt_registry")?;

    if conn_map.get(conn_id).is_none() {
        return Err(rustler::Error::Term(Box::new("Invalid connection ID")));
    }

    let client = conn_map
        .get(conn_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Connection not found")))?
        .clone();

    let (_stored_conn_id, sql) = stmt_registry
        .get(stmt_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Statement not found")))?;

    let sql = sql.clone();

    let decoded_args: Vec<Value> = args
        .into_iter()
        .map(|t| decode_term_to_value(t))
        .collect::<Result<_, _>>()
        .map_err(|e| rustler::Error::Term(Box::new(e)))?;

    drop(stmt_registry);
    drop(conn_map);

    let row = TOKIO_RUNTIME.block_on(async {
        let client_guard = safe_lock_arc(&client, "query_row client")?;
        let conn_guard = safe_lock_arc(&client_guard.client, "query_row conn")?;

        let stmt = conn_guard
            .prepare(&sql)
            .await
            .map_err(|e| rustler::Error::Term(Box::new(format!("Prepare failed: {}", e))))?;

        // Use query_row from Statement API
        let row = stmt.query_row(decoded_args)
            .await
            .map_err(|e| {
                // Check if it's a "no rows" or "multiple rows" error
                let err_str = format!("{}", e);
                if err_str.contains("no rows") || err_str.contains("QueryReturnedNoRows") {
                    rustler::Error::Term(Box::new("no_rows"))
                } else if err_str.contains("multiple rows") {
                    rustler::Error::Term(Box::new("multiple_rows"))
                } else {
                    rustler::Error::Term(Box::new(format!("Query failed: {}", e)))
                }
            })?;

        // Convert row to Elixir terms
        let mut row_terms = Vec::new();
        for i in 0..row.column_count() {
            let term = match row.get(i as i32) {
                Ok(Value::Text(val)) => val.encode(env),
                Ok(Value::Integer(val)) => val.encode(env),
                Ok(Value::Real(val)) => val.encode(env),
                Ok(Value::Blob(val)) => match OwnedBinary::new(val.len()) {
                    Some(mut owned) => {
                        owned.as_mut_slice().copy_from_slice(&val);
                        Binary::from_owned(owned, env).encode(env)
                    }
                    None => nil().encode(env),
                },
                Ok(Value::Null) => nil().encode(env),
                Err(_) => nil().encode(env),
            };
            row_terms.push(term);
        }

        Ok::<_, rustler::Error>(row_terms)
    })?;

    Ok(row.encode(env))
}
```

##### 2. Elixir Wrapper

```elixir
@doc false
def query_row(_conn, _stmt_id, _args), do: :erlang.nif_error(:nif_not_loaded)

@doc """
Execute a prepared statement and return exactly one row.

This is more efficient than `query_stmt/3` when you know the result will be
exactly one row. It will error if the query returns 0 rows or more than 1 row.

## Parameters
  - state: Connection state
  - stmt_id: Statement ID from prepare/2
  - args: Query parameters

## Returns
  - `{:ok, row}` where row is a list of values
  - `{:error, :no_rows}` if query returned no rows
  - `{:error, :multiple_rows}` if query returned more than one row
  - `{:error, reason}` for other failures

## Example
    {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "SELECT name, age FROM users WHERE id = ?")
    {:ok, row} = EctoLibSql.Native.query_row(state, stmt_id, [42])
    # Returns: ["Alice", 30]

    # Error if no rows
    {:error, :no_rows} = EctoLibSql.Native.query_row(state, stmt_id, [999])

    # Error if multiple rows
    {:ok, stmt_id2} = EctoLibSql.Native.prepare(state, "SELECT * FROM users")
    {:error, :multiple_rows} = EctoLibSql.Native.query_row(state, stmt_id2, [])
"""
def query_row(%EctoLibSql.State{conn_id: conn_id}, stmt_id, args) do
  case query_row(conn_id, stmt_id, args) do
    row when is_list(row) ->
      {:ok, row}

    {:error, "no_rows"} ->
      {:error, :no_rows}

    {:error, "multiple_rows"} ->
      {:error, :multiple_rows}

    {:error, reason} ->
      {:error, reason}
  end
end
```

#### Testing Checklist

- [ ] Unit test: Return single row successfully
- [ ] Unit test: Error on zero rows
- [ ] Unit test: Error on multiple rows
- [ ] Integration test: Works with different data types
- [ ] Performance test: Verify it's faster than query + take first

#### Documentation

- [ ] Add examples to Native module
- [ ] Add to AGENTS.md
- [ ] Update CHANGELOG.md

---

## Phase 2: High Value Features (v0.7.0)

### Feature 5: Native execute_batch()

**Priority**: P1 (High)
**Effort**: 3 days
**Dependencies**: None

#### Implementation Steps

##### 1. Rust NIF Function

```rust
#[rustler::nif(schedule = "DirtyIo")]
pub fn execute_batch_native(conn_id: &str, sql: &str) -> NifResult<()> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "execute_batch_native conn_map")?;

    if let Some(client) = conn_map.get(conn_id) {
        let client = client.clone();
        drop(conn_map);

        let result = TOKIO_RUNTIME.block_on(async {
            let client_guard = safe_lock_arc(&client, "execute_batch_native client")
                .map_err(|e| format!("{:?}", e))?;
            let conn_guard = safe_lock_arc(&client_guard.client, "execute_batch_native conn")
                .map_err(|e| format!("{:?}", e))?;

            conn_guard.execute_batch(sql)
                .await
                .map_err(|e| format!("Batch execution failed: {}", e))
        });

        match result {
            Ok(_) => Ok(()),
            Err(e) => Err(rustler::Error::Term(Box::new(e)))
        }
    } else {
        Err(rustler::Error::Term(Box::new("Connection not found")))
    }
}
```

##### 2. Elixir Wrapper

```elixir
@doc false
def execute_batch_native(_conn, _sql), do: :erlang.nif_error(:nif_not_loaded)

@doc """
Execute a batch of SQL statements using Turso's native batch execution.

This is more efficient than our custom batch implementation for multi-statement
SQL strings (like migrations). Statements are separated by semicolons.

## Parameters
  - state: Connection state
  - sql: Multi-statement SQL string

## Example
    sql = \"\"\"
    CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);
    INSERT INTO users VALUES (1, 'Alice');
    INSERT INTO users VALUES (2, 'Bob');
    \"\"\"

    {:ok, state} = EctoLibSql.Native.execute_batch_native(state, sql)
"""
def execute_batch_native(%EctoLibSql.State{conn_id: conn_id} = state, sql) when is_binary(sql) do
  case execute_batch_native(conn_id, sql) do
    :ok -> {:ok, state}
    {:error, reason} -> {:error, reason}
  end
end
```

#### Testing Checklist

- [ ] Unit test: Execute multiple statements
- [ ] Unit test: Error handling on invalid SQL
- [ ] Performance test: Compare vs custom batch implementation
- [ ] Integration test: Large batch (100+ statements)

#### Documentation

- [ ] Document in Native module
- [ ] Update migration guide to use native batch
- [ ] Add to CHANGELOG.md

---

### Features 6-8: Additional Phase 2 Features

*Similar detailed implementation guides would be created for:*

- Feature 6: cacheflush()
- Feature 7: Statement reset()
- Feature 8: MVCC mode

*Each following the same structure with Rust NIF, Elixir wrapper, tests, and docs.*

---

## Phase 3: Polish & Advanced (v0.8.0)

### Features 9-14

*Implementation guides for:*

- Feature 9: JSON helpers
- Feature 10: UUID functions
- Feature 11: Custom VFS
- Feature 12: Vector enhancements
- Feature 13: Connection stats
- Feature 14: Query profiling

---

## Phase 4: Expert Features (v1.0.0)

### Feature 15: WAL API

**Note**: This requires feature-gated build of libsql. Defer until explicit request from community.

---

## General Implementation Checklist

For **every** feature, complete these steps:

### Pre-Implementation

- [ ] Read Turso source code for the feature
- [ ] Review libsql-rs API documentation
- [ ] Design Elixir API (match Ecto conventions)
- [ ] Identify potential error cases
- [ ] Plan backward compatibility
- [ ] Create GitHub issue/task

### Implementation

- [ ] Write Rust NIF function in `lib.rs`
- [ ] Add to `rustler::init!` exports
- [ ] Add NIF stub in `native.ex`
- [ ] Write Elixir wrapper function
- [ ] Handle all error cases (NO unwrap!)
- [ ] Update State struct if needed
- [ ] Add inline documentation (Rust and Elixir)

### Testing

- [ ] Write Rust unit tests (in `tests.rs` or `#[cfg(test)]`)
- [ ] Write Elixir unit tests
- [ ] Write integration tests (local, remote, replica modes)
- [ ] Test error handling
- [ ] Test concurrent access
- [ ] Performance/benchmark test if applicable
- [ ] Run `cargo fmt` and `cargo clippy`
- [ ] Run `mix format --check-formatted`
- [ ] Verify all tests pass

### Documentation

- [ ] Update `AGENTS.md` with API and examples
- [ ] Update `CHANGELOG.md` with changes
- [ ] Add migration notes if breaking
- [ ] Update README.md if user-facing
- [ ] Add doctests to Elixir modules
- [ ] Update CLAUDE.md if architecture changes

### Review & Release

- [ ] Self-review code for quality
- [ ] Run full test suite
- [ ] Check no new warnings
- [ ] Verify examples work
- [ ] Update version numbers
- [ ] Tag release
- [ ] Write release notes

---

## Release Schedule

### v0.6.0 - Critical Features
**Target**: January 2026 (3-4 weeks)
- busy_timeout
- PRAGMA support
- Statement columns
- query_row

### v0.7.0 - High Value
**Target**: February 2026 (3-4 weeks)
- Native execute_batch
- cacheflush
- Statement reset
- MVCC mode
- JSON helpers
- UUID functions

### v0.8.0 - Polish
**Target**: March 2026 (2-3 weeks)
- Vector enhancements
- Connection stats
- Query profiling
- Custom VFS (if needed)

### v1.0.0 - Production Ready
**Target**: April 2026
- All P0-P2 features complete
- Full documentation
- Production battle-tested
- WAL API (if requested)

---

## Success Metrics

### Feature Completeness
- [ ] 95%+ API coverage of libsql-rs
- [ ] All P0 features implemented
- [ ] All P1 features implemented
- [ ] 80%+ P2 features implemented

### Quality
- [ ] 90%+ test coverage
- [ ] Zero unwrap() in production Rust code
- [ ] All tests pass on Ubuntu and macOS
- [ ] No clippy warnings
- [ ] All examples tested

### Documentation
- [ ] Every public function documented
- [ ] 50+ code examples in AGENTS.md
- [ ] Migration guides for breaking changes
- [ ] Video walkthrough (optional)

### Community
- [ ] 5+ community feature requests implemented
- [ ] 10+ GitHub stars
- [ ] Used in 3+ production applications
- [ ] Positive feedback from Turso team

---

## Appendix: Quick Command Reference

```bash
# Before starting
git checkout -b feature/name
mix deps.get

# Development cycle
mix format
cd native/ecto_libsql && cargo fmt && cargo clippy
cd ../..
mix test
cd native/ecto_libsql && cargo test

# Before commit
mix format --check-formatted
mix test --trace
mix test --exclude turso_remote

# Release
mix hex.publish
git tag v0.X.Y
git push && git push --tags
```

---

**Document Version**: 1.0.0
**Last Updated**: 2025-12-01
**Next Review**: After Phase 1 completion
**Maintained By**: Development Team
