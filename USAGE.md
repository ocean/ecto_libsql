# ecto_libsql - Developer Guide (Application Usage)

> **Purpose**: Guide for AI agents helping developers **USE** ecto_libsql in their applications.
> For **developing/maintaining the library itself**, see [CLAUDE.md](CLAUDE.md).

## Table of Contents

- [Quick Start](#quick-start)
- [Connection Management](#connection-management)
- [UPSERT / on_conflict](#upsert--on_conflict)
- [Advanced Features](#advanced-features)
  - [Transactions & Savepoints](#transactions--savepoints)
  - [Named Parameters](#named-parameters)
  - [Prepared Statements](#prepared-statements)
  - [Batch Operations](#batch-operations)
  - [Cursor Streaming](#cursor-streaming)
  - [Vector Search](#vector-search)
  - [R*Tree Spatial Indexing](#rtree-spatial-indexing)
  - [Connection Utilities](#connection-utilities)
  - [PRAGMA Configuration](#pragma-configuration)
  - [Encryption](#encryption)
  - [JSON Helpers](#json-helpers)
- [Ecto Integration](#ecto-integration)
  - [Configuration](#configuration)
  - [Schemas and Migrations](#schemas-and-migrations)
  - [LibSQL Migration Extensions](#libsql-migration-extensions)
  - [Phoenix & Production](#phoenix--production)
  - [Type Encoding Gotchas](#type-encoding-gotchas)
  - [Limitations and Known Issues](#limitations-and-known-issues)
  - [Type Mappings](#type-mappings)
- [API Reference](#api-reference)
- [Troubleshooting](#troubleshooting)

---

## Quick Start

```elixir
# mix.exs
{:ecto_libsql, "~> 0.8.0"}
```

```elixir
{:ok, state} = EctoLibSql.connect(database: "myapp.db")

{:ok, _, _, state} = EctoLibSql.handle_execute(
  "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT)",
  [], [], state
)

{:ok, _, _, state} = EctoLibSql.handle_execute(
  "INSERT INTO users (name, email) VALUES (?, ?)",
  ["Alice", "alice@example.com"], [], state
)

{:ok, _query, result, _state} = EctoLibSql.handle_execute(
  "SELECT * FROM users WHERE name = ?", ["Alice"], [], state
)
# %EctoLibSql.Result{columns: ["id", "name", "email"], rows: [[1, "Alice", "alice@example.com"]], num_rows: 1}
```

---

## Connection Management

### Three Modes

```elixir
# Local (development / embedded)
{:ok, state} = EctoLibSql.connect(database: "local.db")

# Remote Turso
{:ok, state} = EctoLibSql.connect(
  uri: "libsql://my-database.turso.io",
  auth_token: System.get_env("TURSO_AUTH_TOKEN")
)

# Remote Replica (recommended for production — local reads, synced writes)
{:ok, state} = EctoLibSql.connect(
  uri: "libsql://my-database.turso.io",
  auth_token: System.get_env("TURSO_AUTH_TOKEN"),
  database: "replica.db",
  sync: true
)
```

Use `wss://` instead of `libsql://` for WebSocket protocol (~30–50% lower latency).

### Encryption

```elixir
{:ok, state} = EctoLibSql.connect(
  database: "secure.db",
  encryption_key: System.get_env("DB_ENCRYPTION_KEY")  # Min 32 chars.
)
```

Encryption (AES-256-CBC) is transparent after connect. Works with both local and replica modes.

---

## UPSERT / on_conflict

Ecto `on_conflict` is fully supported. **`:conflict_target` is required for LibSQL/SQLite** (unlike PostgreSQL).

```elixir
# Ignore duplicates
Repo.insert(changeset, on_conflict: :nothing, conflict_target: [:email])

# Replace all fields
Repo.insert(changeset, on_conflict: :replace_all, conflict_target: [:email])

# Replace specific fields
Repo.insert(changeset, on_conflict: {:replace, [:name, :updated_at]}, conflict_target: [:email])

# Replace all except specific fields
Repo.insert(changeset, on_conflict: {:replace_all_except, [:id, :inserted_at]}, conflict_target: [:email])

# Query-based update
Repo.insert(changeset,
  on_conflict: [set: [name: "Updated", updated_at: DateTime.utc_now()]],
  conflict_target: [:email]
)

# Increment on conflict
Repo.insert(changeset, on_conflict: [inc: [count: 1]], conflict_target: [:key])
```

Named constraints (`ON CONFLICT ON CONSTRAINT name`) are not supported.

---

## Advanced Features

### Transactions & Savepoints

```elixir
# Standard transaction.
{:ok, :begin, state} = EctoLibSql.handle_begin([], state)
# ... operations ...
{:ok, _, state} = EctoLibSql.handle_commit([], state)
# Or: {:ok, _, state} = EctoLibSql.handle_rollback([], state)

# Transaction behaviour (locking strategy).
{:ok, state} = EctoLibSql.Native.begin(state, behavior: :deferred)   # Default: lock on first write.
{:ok, state} = EctoLibSql.Native.begin(state, behavior: :immediate)  # Acquire write lock immediately.
{:ok, state} = EctoLibSql.Native.begin(state, behavior: :exclusive)  # Exclusive lock.
{:ok, state} = EctoLibSql.Native.begin(state, behavior: :read_only)  # No locks.
```

**Savepoints** enable partial rollback within a transaction:

```elixir
{:ok, :begin, state} = EctoLibSql.handle_begin([], state)

{:ok, state} = EctoLibSql.Native.create_savepoint(state, "sp1")
# ... operations ...
{:ok, state} = EctoLibSql.Native.rollback_to_savepoint_by_name(state, "sp1")  # Undo to sp1, transaction stays active.
# Or:
{:ok, state} = EctoLibSql.Native.release_savepoint_by_name(state, "sp1")      # Commit sp1's changes.

{:ok, _, state} = EctoLibSql.handle_commit([], state)
```

### Named Parameters

SQLite supports three named parameter syntaxes. Pass a map instead of a list:

```elixir
# :name, @name, or $name syntax — all equivalent.
{:ok, _, _, state} = EctoLibSql.handle_execute(
  "SELECT * FROM users WHERE email = :email AND status = :status",
  %{"email" => "alice@example.com", "status" => "active"},
  [], state
)

# Also works with INSERT/UPDATE/DELETE.
{:ok, _, _, state} = EctoLibSql.handle_execute(
  "INSERT INTO users (name, email) VALUES (:name, :email)",
  %{"name" => "Alice", "email" => "alice@example.com"},
  [], state
)
```

Positional `?` parameters still work unchanged. Do not mix named and positional within a single statement.

### Prepared Statements

Cached after first preparation — ~10–15x faster for repeated queries. Bindings are cleared automatically between executions via `stmt.reset()`.

```elixir
# Prepare and cache.
{:ok, stmt_id} = EctoLibSql.Native.prepare(state, "SELECT * FROM users WHERE email = ?")

# Execute SELECT — returns rows.
{:ok, result} = EctoLibSql.Native.query_stmt(state, stmt_id, ["alice@example.com"])

# Execute INSERT/UPDATE/DELETE — returns affected rows count.
# SQL must be re-supplied (used for replica sync detection).
{:ok, num_rows} = EctoLibSql.Native.execute_stmt(
  state, stmt_id,
  "INSERT INTO users (name, email) VALUES (?, ?)",  # Same SQL as prepare.
  ["Alice", "alice@example.com"]
)

# Clean up.
:ok = EctoLibSql.Native.close_stmt(stmt_id)
```

**Statement introspection:**

```elixir
{:ok, param_count} = EctoLibSql.Native.stmt_parameter_count(state, stmt_id)
{:ok, col_count}   = EctoLibSql.Native.stmt_column_count(state, stmt_id)
{:ok, col_name}    = EctoLibSql.Native.stmt_column_name(state, stmt_id, 0)  # 0-based index.
{:ok, param_name}  = EctoLibSql.Native.stmt_parameter_name(state, stmt_id, 1)  # 1-based; nil for positional ?.
{:ok, columns}     = EctoLibSql.Native.get_stmt_columns(state, stmt_id)  # [{name, origin_name, decl_type}]
:ok                = EctoLibSql.Native.reset_stmt(state, stmt_id)  # Reset to initial state for reuse.
```

### Batch Operations

```elixir
statements = [
  {"INSERT INTO users (name, email) VALUES (?, ?)", ["Alice", "alice@example.com"]},
  {"INSERT INTO users (name, email) VALUES (?, ?)", ["Bob", "bob@example.com"]},
]

# Non-transactional — each executes independently; failures don't affect others.
{:ok, results} = EctoLibSql.Native.batch(state, statements)

# Transactional — all-or-nothing.
{:ok, results} = EctoLibSql.Native.batch_transactional(state, statements)

# Raw SQL string (multiple statements separated by semicolons).
{:ok, _} = EctoLibSql.Native.execute_batch_sql(state, "CREATE TABLE ...; INSERT INTO ...; ...")
{:ok, _} = EctoLibSql.Native.execute_transactional_batch_sql(state, sql)
```

### Cursor Streaming

For large result sets. `Repo.stream/2` is **not supported** — use `DBConnection.stream/4` instead:

```elixir
stream = DBConnection.stream(
  conn,
  %EctoLibSql.Query{statement: "SELECT * FROM large_table"},
  [],
  max_rows: 500  # Default 500.
)

stream
|> Stream.flat_map(fn %EctoLibSql.Result{rows: rows} -> rows end)
|> Stream.each(&process_row/1)
|> Stream.run()
```

### Vector Search

```elixir
# Define column type for schema/migration.
vector_col = EctoLibSql.Native.vector_type(1536, :f32)  # Or :f64.
# Returns: "F32_BLOB(1536)"

# Insert with vector() SQL function.
vec = EctoLibSql.Native.vector([0.1, 0.2, 0.3, ...])  # Converts list to string format.
{:ok, _, _, state} = EctoLibSql.handle_execute(
  "INSERT INTO docs (content, embedding) VALUES (?, vector(?))",
  ["Hello world", vec], [], state
)

# Similarity search.
distance_sql = EctoLibSql.Native.vector_distance_cos("embedding", query_embedding)
# Returns: "vector_distance_cos(embedding, '[0.1,0.2,...]')"

{:ok, _, result, _} = EctoLibSql.handle_execute(
  "SELECT id, content, #{distance_sql} AS distance FROM docs ORDER BY distance LIMIT 10",
  [], [], state
)
```

### R*Tree Spatial Indexing

R*Tree is a SQLite virtual table for efficient multidimensional range queries (geographic bounds, time ranges, etc.).

**Requirements:**
- First column must be named `id` (integer primary key)
- Remaining columns are min/max pairs (1–5 dimensions)
- Total columns must be **odd**: 3, 5, 7, 9, or 11
- Not compatible with `:strict`, `:random_rowid`, or `:without_rowid`

```elixir
# In a migration — Ecto's default id column + 2D bounds = 5 columns (odd ✓).
create table(:geo_regions, options: [rtree: true]) do
  add :min_lat, :float
  add :max_lat, :float
  add :min_lng, :float
  add :max_lng, :float
end

# Query: find regions containing point (-33.87, 151.21).
result = Repo.query!("""
  SELECT id FROM geo_regions
  WHERE min_lat <= -33.87 AND max_lat >= -33.87
    AND min_lng <= 151.21 AND max_lng >= 151.21
""")
```

If using `primary_key: false`, add an explicit `add :id, :integer, primary_key: true` as the first column.

### Connection Utilities

```elixir
# Configure how long to wait when the database is locked (ms).
{:ok, state} = EctoLibSql.Native.busy_timeout(state, 10_000)

# Reset connection state (clears prepared statements, releases locks, rolls back open transactions).
{:ok, state} = EctoLibSql.Native.reset(state)

# Interrupt a long-running query from another process.
:ok = EctoLibSql.Native.interrupt(state)
```

### PRAGMA Configuration

```elixir
# Foreign keys.
{:ok, state}   = EctoLibSql.Pragma.enable_foreign_keys(state)
{:ok, enabled} = EctoLibSql.Pragma.foreign_keys(state)         # true/false.

# Journal mode.
{:ok, state} = EctoLibSql.Pragma.set_journal_mode(state, :wal)
{:ok, mode}  = EctoLibSql.Pragma.journal_mode(state)            # :wal, :delete, etc.

# Cache size (negative = KB, positive = pages).
{:ok, state} = EctoLibSql.Pragma.set_cache_size(state, -10_000)

# Synchronous level.
{:ok, state} = EctoLibSql.Pragma.set_synchronous(state, :normal)  # :off | :normal | :full | :extra.

# Table introspection.
{:ok, columns} = EctoLibSql.Pragma.table_info(state, "users")  # [%{name: ..., type: ..., ...}]
{:ok, tables}  = EctoLibSql.Pragma.table_list(state)            # ["users", "posts", ...]

# Schema versioning.
{:ok, state}   = EctoLibSql.Pragma.set_user_version(state, 5)
{:ok, version} = EctoLibSql.Pragma.user_version(state)
```

### Encryption

```elixir
# Local encrypted database.
{:ok, state} = EctoLibSql.connect(
  database: "secure.db",
  encryption_key: System.get_env("DB_ENCRYPTION_KEY")
)

# Encrypted remote replica.
{:ok, state} = EctoLibSql.connect(
  uri: "libsql://my-database.turso.io",
  auth_token: System.get_env("TURSO_AUTH_TOKEN"),
  database: "encrypted_replica.db",
  encryption_key: System.get_env("DB_ENCRYPTION_KEY"),
  sync: true
)
```

Encryption key must be at least 32 characters. Use environment variables or a secret manager — never hard-code keys.

### JSON Helpers

`EctoLibSql.JSON` provides helpers for libSQL's built-in JSON1 (text JSON and JSONB binary format).

**Key functions:**
```elixir
alias EctoLibSql.JSON

{:ok, value}    = JSON.extract(state, json, "$.user.name")           # Extract value at path.
{:ok, type}     = JSON.type(state, json, "$.count")                  # "integer" | "text" | "array" | "object" | etc.
{:ok, valid?}   = JSON.is_valid(state, json)                         # Boolean.
{:ok, len}      = JSON.json_length(state, json)                      # Array/object length.
{:ok, depth}    = JSON.depth(state, json)                            # Nesting depth.
{:ok, keys}     = JSON.keys(state, json)                             # Object keys as JSON array string.
{:ok, json}     = JSON.set(state, json, "$.key", value)             # Create or replace path.
{:ok, json}     = JSON.replace(state, json, "$.key", value)         # Replace existing path only.
{:ok, json}     = JSON.insert(state, json, "$.key", value)          # Add new path only.
{:ok, json}     = JSON.remove(state, json, "$.key")                 # Remove path (or list of paths).
{:ok, json}     = JSON.patch(state, json, patch_json)               # RFC 7396 JSON Merge Patch.
{:ok, arr}      = JSON.array(state, [1, 2.5, "hello", nil])         # Build JSON array.
{:ok, obj}      = JSON.object(state, ["name", "Alice", "age", 30])  # Build JSON object (alternating pairs).
{:ok, items}    = JSON.each(state, json, "$")                        # [{key, value, type}]
{:ok, tree}     = JSON.tree(state, json, "$")                        # All nested values with paths.
{:ok, jsonb}    = JSON.convert(state, json, :jsonb)                  # Convert to binary JSONB format.
{:ok, canon}    = JSON.convert(state, json, :json)                   # Canonical text JSON.
fragment        = JSON.arrow_fragment("col", "key")                  # "col -> 'key'" (returns JSON).
fragment        = JSON.arrow_fragment("col", "key", :double_arrow)   # "col ->> 'key'" (returns SQL type).
```

**set vs replace vs insert vs patch:**

| Function | Creates new path? | Updates existing? | Notes |
|----------|------------------|-------------------|-------|
| `set` | ✅ | ✅ | Use JSON paths (`$.key`) |
| `replace` | ❌ | ✅ | Use JSON paths (`$.key`) |
| `insert` | ✅ | ❌ | Use JSON paths (`$.key`) |
| `patch` | ✅ | ✅ | RFC 7396 — top-level object keys only; set key to `null` to remove |

JSONB binary format is ~5–10% smaller and faster to process. All JSON functions accept both text and JSONB transparently.

---

## Ecto Integration

### Configuration

```elixir
# config/dev.exs — local
config :my_app, MyApp.Repo,
  adapter: Ecto.Adapters.LibSql,
  database: "my_app_dev.db",
  pool_size: 5

# config/runtime.exs — production (remote replica recommended)
if config_env() == :prod do
  config :my_app, MyApp.Repo,
    adapter: Ecto.Adapters.LibSql,
    database: "prod_replica.db",
    uri: System.get_env("TURSO_URL") || raise("TURSO_URL not set"),
    auth_token: System.get_env("TURSO_AUTH_TOKEN") || raise("TURSO_AUTH_TOKEN not set"),
    sync: true,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")
end
```

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.LibSql
end
```

### Schemas and Migrations

Standard Ecto schemas and changesets work as expected. Run migrations with:

```bash
mix ecto.create && mix ecto.migrate
```

Basic migration example:

```elixir
defmodule MyApp.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :name, :string, null: false
      add :email, :string, null: false
      add :age, :integer
      timestamps()
    end

    create unique_index(:users, [:email])
  end
end
```

### LibSQL Migration Extensions

LibSQL provides extensions beyond standard SQLite:

#### STRICT Tables (type enforcement)

```elixir
create table(:users, strict: true) do
  add :name, :string, null: false   # TEXT only.
  add :age, :integer                # INTEGER only.
  add :score, :float                # REAL only.
  timestamps()
end

# Also combinable with other options.
create table(:api_keys, options: [strict: true, random_rowid: true]) do
  # ...
end
```

Requires SQLite 3.37+ / libSQL. Allowed column types: `INT`/`INTEGER`, `TEXT`, `BLOB`, `REAL`, `NULL`.

#### RANDOM ROWID (anti-enumeration)

```elixir
create table(:sessions, options: [random_rowid: true]) do
  add :token, :string, null: false
  add :user_id, references(:users, on_delete: :delete_all)
  add :expires_at, :utc_datetime
  timestamps()
end
```

Generates pseudorandom row IDs instead of sequential integers. Mutually exclusive with `WITHOUT ROWID` and `AUTOINCREMENT`.

#### ALTER COLUMN (libSQL only)

```elixir
alter table(:users) do
  modify :age, :string, default: "0"          # Change type.
  modify :email, :string, null: false         # Add NOT NULL.
  modify :status, :string, default: "active"  # Add DEFAULT.
  modify :team_id, references(:teams, on_delete: :nilify_all)  # Add FK.
end
```

Changes apply only to **new or updated rows** — existing data is not revalidated. Not available in standard SQLite.

#### Generated / Computed Columns (SQLite 3.31+)

```elixir
create table(:users) do
  add :first_name, :string, null: false
  add :last_name, :string, null: false
  add :full_name, :string, generated: "first_name || ' ' || last_name"              # Virtual (not stored).
  add :search_key, :string, generated: "lower(email)", stored: true                 # Stored (persisted).
  timestamps()
end
```

Constraints: cannot have DEFAULT values, cannot be PRIMARY KEY, expression must be deterministic. Only STORED columns can be indexed.

### Phoenix & Production

```elixir
# mix phx.new my_app --database libsqlex
# Or add to existing project — config as shown above.

# Standard Phoenix context pattern works unchanged.
defmodule MyApp.Accounts do
  import Ecto.Query
  alias MyApp.{Repo, User}

  def list_users, do: Repo.all(User)
  def get_user!(id), do: Repo.get!(User, id)
  def create_user(attrs), do: %User{} |> User.changeset(attrs) |> Repo.insert()
end
```

**Production setup:**
```bash
turso db create my-app-prod
turso db show my-app-prod --url     # → TURSO_URL
turso db tokens create my-app-prod  # → TURSO_AUTH_TOKEN
```

### Type Encoding Gotchas

The following Elixir types are **automatically encoded** when passed as top-level query parameters:

| Elixir Type | Stored As | Example |
|-------------|-----------|---------|
| `DateTime` | ISO8601 string | `"2026-01-13T03:45:23.123456Z"` |
| `NaiveDateTime` | ISO8601 string | `"2026-01-13T03:45:23.123456"` |
| `Date` | ISO8601 string | `"2026-01-13"` |
| `Time` | ISO8601 string | `"14:30:45.000000"` |
| `true` / `false` | `1` / `0` | Integer |
| `Decimal` | String | `"123.45"` |
| `nil` / `:null` | NULL | SQL NULL |
| `Ecto.UUID` | String | UUID text |

**⚠️ Nested structures are NOT automatically encoded:**

```elixir
# ❌ Fails — DateTime inside map is not auto-encoded.
SQL.query!(Repo, "INSERT INTO events (metadata) VALUES (?)", [
  %{"created_at" => DateTime.utc_now(), "data" => "value"}
])

# ✅ Pre-encode nested temporal values manually.
json = Jason.encode!(%{"created_at" => DateTime.to_iso8601(DateTime.utc_now()), "data" => "value"})
SQL.query!(Repo, "INSERT INTO events (metadata) VALUES (?)", [json])
```

Third-party date types (e.g. `Timex.DateTime`) must be converted to standard Elixir types before passing as parameters.

### Limitations and Known Issues

#### `freeze_replica/1` — Not Supported

`EctoLibSql.Native.freeze_replica/1` returns `{:error, :unsupported}`. Workaround: copy the replica `.db` file and configure your app to use it directly.

#### `Repo.stream/2` — Not Supported

Use `DBConnection.stream/4` with `max_rows:` instead (see [Cursor Streaming](#cursor-streaming)).

#### SQLite / Ecto Compatibility

The following Ecto query features do not work due to SQLite limitations:

| Feature | Limitation |
|---------|------------|
| `selected_as()` with GROUP BY | SQLite doesn't support column aliases in GROUP BY |
| `exists()` with `parent_as()` | Complex nested query correlation unsupported |
| `fragment(literal(...))` / `fragment(identifier(...))` | Not supported in SQLite fragments |
| `ago(N, unit)` | Does not work with TEXT-based timestamps |
| `{:array, _}` type | Not supported — use JSON or separate tables |
| Mixed arithmetic (string + float) | SQLite returns TEXT instead of coercing to REAL |
| Case-insensitive text comparison | TEXT is case-sensitive by default — use `COLLATE NOCASE` |

**Compatibility summary: ~74% of Ecto features pass (31/42 tests). All failures are SQLite limitations, not adapter bugs.**

### Type Mappings

| Ecto Type | SQLite Type | Notes |
|-----------|-------------|-------|
| `:id` / `:integer` | `INTEGER` | ✅ |
| `:string` | `TEXT` | ✅ |
| `:binary_id` / `:uuid` | `TEXT` | ✅ Stored as UUID text |
| `:binary` | `BLOB` | ✅ |
| `:boolean` | `INTEGER` | ✅ 0 = false, 1 = true |
| `:float` | `REAL` | ✅ |
| `:decimal` | `DECIMAL` | ✅ |
| `:text` | `TEXT` | ✅ |
| `:date` / `:time` | `DATE` / `TIME` | ✅ ISO8601 |
| `:naive_datetime` / `:utc_datetime` | `DATETIME` | ✅ ISO8601 |
| `:*_usec` variants | `DATETIME` | ✅ ISO8601 with microseconds |
| `:map` / `:json` | `TEXT` | ✅ JSON string |
| `{:array, _}` | — | ❌ Not supported |

Use `@timestamps_opts [type: :utc_datetime_usec]` on schemas requiring microsecond precision.

### Migration Notes Summary

```elixir
# ✅ Fully supported
create table(:users)                                    # CREATE TABLE
alter table(:users) do: add :field, :type              # ADD COLUMN
alter table(:users) do: remove :field                  # DROP COLUMN (libSQL / SQLite 3.35.0+)
drop table(:users)                                      # DROP TABLE
create index(:users, [:email])                          # CREATE INDEX
rename table(:old), to: table(:new)                     # RENAME TABLE
rename table(:users), :old_field, to: :new_field        # RENAME COLUMN

# ✅ libSQL extensions (not in standard SQLite)
create table(:sessions, options: [random_rowid: true])  # RANDOM ROWID
create table(:users, strict: true)                      # STRICT type enforcement
alter table(:users) do: modify :age, :string            # ALTER COLUMN

# ✅ SQLite 3.31+ / libSQL
add :full_name, :string, generated: "first || ' ' || last"         # VIRTUAL computed column
add :total, :float, generated: "price * qty", stored: true         # STORED computed column
```

For standard SQLite (without libSQL's `ALTER COLUMN`), use table recreation: create new table → copy data → drop old → rename.

---

## API Reference

### Connection

| Function | Signature | Returns |
|----------|-----------|---------|
| `EctoLibSql.connect/1` | `(opts)` | `{:ok, state}` \| `{:error, reason}` |
| `EctoLibSql.disconnect/2` | `(opts, state)` | `:ok` |
| `EctoLibSql.ping/1` | `(state)` | `{:ok, state}` \| `{:disconnect, reason, state}` |

### Queries

| Function | Signature | Returns |
|----------|-----------|---------|
| `EctoLibSql.handle_execute/4` | `(sql_or_query, params, opts, state)` | `{:ok, query, result, state}` \| `{:error, query, reason, state}` |

### Transactions

| Function | Signature | Returns |
|----------|-----------|---------|
| `EctoLibSql.handle_begin/2` | `(opts, state)` | `{:ok, :begin, state}` \| `{:error, reason, state}` |
| `EctoLibSql.handle_commit/2` | `(opts, state)` | `{:ok, result, state}` \| `{:error, reason, state}` |
| `EctoLibSql.handle_rollback/2` | `(opts, state)` | `{:ok, result, state}` \| `{:error, reason, state}` |
| `EctoLibSql.Native.begin/2` | `(state, behavior: atom)` | `{:ok, state}` \| `{:error, reason}` |

### Savepoints

| Function | Signature | Returns |
|----------|-----------|---------|
| `EctoLibSql.Native.create_savepoint/2` | `(state, name)` | `{:ok, state}` \| `{:error, reason}` |
| `EctoLibSql.Native.release_savepoint_by_name/2` | `(state, name)` | `{:ok, state}` \| `{:error, reason}` |
| `EctoLibSql.Native.rollback_to_savepoint_by_name/2` | `(state, name)` | `{:ok, state}` \| `{:error, reason}` |

### Prepared Statements

| Function | Signature | Returns |
|----------|-----------|---------|
| `EctoLibSql.Native.prepare/2` | `(state, sql)` | `{:ok, stmt_id}` \| `{:error, reason}` |
| `EctoLibSql.Native.query_stmt/3` | `(state, stmt_id, args)` | `{:ok, result}` \| `{:error, reason}` |
| `EctoLibSql.Native.execute_stmt/4` | `(state, stmt_id, sql, args)` | `{:ok, num_rows}` \| `{:error, reason}` |
| `EctoLibSql.Native.close_stmt/1` | `(stmt_id)` | `:ok` \| `{:error, reason}` |
| `EctoLibSql.Native.reset_stmt/2` | `(state, stmt_id)` | `:ok` \| `{:error, reason}` |
| `EctoLibSql.Native.stmt_parameter_count/2` | `(state, stmt_id)` | `{:ok, count}` |
| `EctoLibSql.Native.stmt_column_count/2` | `(state, stmt_id)` | `{:ok, count}` |
| `EctoLibSql.Native.stmt_column_name/3` | `(state, stmt_id, index)` | `{:ok, name}` |
| `EctoLibSql.Native.stmt_parameter_name/3` | `(state, stmt_id, index)` | `{:ok, name \| nil}` |
| `EctoLibSql.Native.get_stmt_columns/2` | `(state, stmt_id)` | `{:ok, [{name, origin_name, decl_type}]}` |

### Batch

| Function | Signature | Returns |
|----------|-----------|---------|
| `EctoLibSql.Native.batch/2` | `(state, [{sql, params}])` | `{:ok, results}` \| `{:error, reason}` |
| `EctoLibSql.Native.batch_transactional/2` | `(state, [{sql, params}])` | `{:ok, results}` \| `{:error, reason}` |
| `EctoLibSql.Native.execute_batch_sql/2` | `(state, sql_string)` | `{:ok, state}` \| `{:error, reason}` |
| `EctoLibSql.Native.execute_transactional_batch_sql/2` | `(state, sql_string)` | `{:ok, state}` \| `{:error, reason}` |

### Cursors

| Function | Signature | Returns |
|----------|-----------|---------|
| `EctoLibSql.handle_declare/4` | `(query, params, opts, state)` | `{:ok, query, cursor, state}` \| `{:error, reason, state}` |
| `EctoLibSql.handle_fetch/4` | `(query, cursor, opts, state)` | `{:cont, result, state}` \| `{:deallocated, result, state}` \| `{:error, reason, state}` |
| `EctoLibSql.handle_deallocate/4` | `(query, cursor, opts, state)` | `{:ok, result, state}` \| `{:error, reason, state}` |

### Metadata

| Function | Signature | Returns |
|----------|-----------|---------|
| `EctoLibSql.Native.get_last_insert_rowid/1` | `(state)` | `integer` |
| `EctoLibSql.Native.get_changes/1` | `(state)` | `integer` |
| `EctoLibSql.Native.get_total_changes/1` | `(state)` | `integer` |
| `EctoLibSql.Native.get_is_autocommit/1` | `(state)` | `boolean` |

### Vector

| Function | Signature | Returns |
|----------|-----------|---------|
| `EctoLibSql.Native.vector/1` | `(list_of_numbers)` | `String.t()` |
| `EctoLibSql.Native.vector_type/2` | `(dimensions, :f32 \| :f64)` | `String.t()` — e.g. `"F32_BLOB(1536)"` |
| `EctoLibSql.Native.vector_distance_cos/2` | `(column, vector)` | `String.t()` — SQL expression |

### Connection Utilities

| Function | Signature | Returns |
|----------|-----------|---------|
| `EctoLibSql.Native.busy_timeout/2` | `(state, ms)` | `{:ok, state}` \| `{:error, reason}` |
| `EctoLibSql.Native.reset/1` | `(state)` | `{:ok, state}` \| `{:error, reason}` |
| `EctoLibSql.Native.interrupt/1` | `(state)` | `:ok` |

### Replication

| Function | Signature | Returns |
|----------|-----------|---------|
| `EctoLibSql.Native.sync/1` | `(state)` | `{:ok, message}` \| `{:error, reason}` |
| `EctoLibSql.Native.get_frame_number_for_replica/1` | `(state)` | `{:ok, frame_number}` |
| `EctoLibSql.Native.sync_until_frame/2` | `(state, frame_number)` | `{:ok, state}` \| `{:error, reason}` |
| `EctoLibSql.Native.flush_and_get_frame/1` | `(state)` | `{:ok, frame_number}` |
| `EctoLibSql.Native.max_write_replication_index/1` | `(state)` | `{:ok, frame_number}` |

### Extension Loading

| Function | Signature | Returns |
|----------|-----------|---------|
| `EctoLibSql.Native.enable_extensions/2` | `(state, boolean)` | `:ok` \| `{:error, reason}` |
| `EctoLibSql.Native.load_ext/3` | `(state, path, entry_point \| nil)` | `:ok` \| `{:error, reason}` |

---

## Troubleshooting

### `database is locked`

Use `IMMEDIATE` transactions for write-heavy workloads, or increase the busy timeout:

```elixir
{:ok, state} = EctoLibSql.Native.busy_timeout(state, 10_000)
{:ok, state} = EctoLibSql.Native.begin(state, behavior: :immediate)
# Or via Repo: Repo.transaction(fn -> ... end, timeout: 15_000)
```

### `nif_not_loaded`

Recompile the native code:
```bash
mix deps.clean ecto_libsql --build && mix deps.get && mix compile
```

### Vector search not working

Verify the embedding list dimensions match the column type, and wrap the vector parameter in the `vector()` SQL function:
```elixir
"INSERT INTO docs (embedding) VALUES (vector(?))"
```

### `connection failed: authentication error` (Turso)

Verify credentials with `turso db show <name>` and `turso db tokens create <name>`. URI must include the `libsql://` prefix.

### Type mismatch on STRICT table

Insert types must match exactly — SQLite won't coerce (e.g., passing `"30"` for an `INTEGER` column will fail).

---

**Last Updated**: 2026-02-26 | **License**: Apache 2.0 | **Repository**: https://github.com/ocean/ecto_libsql
