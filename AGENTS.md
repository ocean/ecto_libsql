# ecto_libsql - Comprehensive Developer Guide (Application Usage)

> **Purpose**: Guide for AI agents helping developers **USE** ecto_libsql in their applications
>
> **⚠️ IMPORTANT**: This guide is for **using ecto_libsql in your applications**.  
> **🔧 For developing/maintaining the ecto_libsql library itself**, see [CLAUDE.md](https://github.com/ocean/ecto_libsql/blob/main/CLAUDE.md) instead.

Welcome to ecto_libsql! This guide provides comprehensive documentation, API reference, and practical examples for building applications with LibSQL/Turso in Elixir using the Ecto adapter.

## ℹ️ About This Guide

**AGENTS.md** is the application usage guide for developers building apps with ecto_libsql. It covers:
- How to integrate ecto_libsql into your Elixir/Phoenix application
- Configuration and connection management
- Ecto schemas, migrations, and queries
- Advanced features (vector search, encryption, batching)
- Real-world usage examples and patterns
- Performance optimisation for your applications

**If you're working ON the ecto_libsql codebase itself** (contributing, fixing bugs, adding features), see [CLAUDE.md](https://github.com/ocean/ecto_libsql/blob/main/CLAUDE.md) for internal development documentation.

## Table of Contents

- [Quick Start](#quick-start)
- [Connection Management](#connection-management)
- [Basic Operations](#basic-operations)
- [Advanced Features](#advanced-features)
  - [Transactions](#transactions)
  - [Prepared Statements](#prepared-statements)
  - [Batch Operations](#batch-operations)
  - [Cursor Streaming](#cursor-streaming)
  - [Connection Management](#connection-management)
  - [PRAGMA Configuration](#pragma-configuration)
  - [Vector Search](#vector-search)
  - [Encryption](#encryption)
- [Ecto Integration](#ecto-integration)
  - [Quick Start with Ecto](#quick-start-with-ecto)
  - [Schemas and Changesets](#schemas-and-changesets)
  - [Migrations](#migrations)
  - [Queries](#basic-queries)
  - [Associations](#associations-and-preloading)
  - [Transactions](#transactions)
  - [Phoenix Integration](#phoenix-integration)
  - [Production Deployment](#production-deployment-with-turso)
  - [Limitations and Known Issues](#limitations-and-known-issues)
- [API Reference](#api-reference)
- [Real-World Examples](#real-world-examples)
- [Performance Guide](#performance-guide)
- [Error Handling](#error-handling)
- [Troubleshooting](#troubleshooting)

---

## Quick Start

### Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:ecto_libsql, "~> 0.8.0"}
  ]
end
```

### Your First Query

```elixir
# Connect to a local database
{:ok, state} = EctoLibSql.connect(database: "myapp.db")

# Create a table
{:ok, _, _, state} = EctoLibSql.handle_execute(
  "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT)",
  [],
  [],
  state
)

# Insert data
{:ok, _, _, state} = EctoLibSql.handle_execute(
  "INSERT INTO users (name, email) VALUES (?, ?)",
  ["Alice", "alice@example.com"],
  [],
  state
)

# Query data
{:ok, _query, result, _state} = EctoLibSql.handle_execute(
  "SELECT * FROM users WHERE name = ?",
  ["Alice"],
  [],
  state
)

IO.inspect(result)
# %EctoLibSql.Result{
#   columns: ["id", "name", "email"],
#   rows: [[1, "Alice", "alice@example.com"]],
#   num_rows: 1
# }
```

---

## Connection Management

EctoLibSql supports three connection modes, each optimised for different use cases.

### Local Mode

Perfect for embedded databases, development, and single-instance applications.

```elixir
opts = [database: "local.db"]
{:ok, state} = EctoLibSql.connect(opts)
```

**Use cases:**
- Development and testing
- Embedded applications
- Single-instance desktop apps
- SQLite migration projects

### Remote Mode

Direct connection to Turso for globally distributed databases.

```elixir
opts = [
  uri: "libsql://my-database.turso.io",
  auth_token: System.get_env("TURSO_AUTH_TOKEN")
]
{:ok, state} = EctoLibSql.connect(opts)
```

**Use cases:**
- Cloud-native applications
- Multi-region deployments
- Serverless functions
- High availability requirements

### Remote Replica Mode

Best of both worlds: local performance with remote synchronisation.

```elixir
opts = [
  uri: "libsql://my-database.turso.io",
  auth_token: System.get_env("TURSO_AUTH_TOKEN"),
  database: "replica.db",
  sync: true  # Auto-sync on writes
]
{:ok, state} = EctoLibSql.connect(opts)
```

**Use cases:**
- Read-heavy workloads
- Edge computing
- Offline-first applications
- Mobile backends

### WebSocket vs HTTP

For lower latency, use WebSocket protocol:

```elixir
# HTTP (default)
opts = [uri: "https://my-database.turso.io", auth_token: token]

# WebSocket (lower latency, multiplexing)
opts = [uri: "wss://my-database.turso.io", auth_token: token]
```

**WebSocket benefits:**
- ~30-50% lower latency
- Better connection pooling
- Multiplexed queries
- Real-time updates

### Connection with Encryption

Encrypt local databases and replicas:

```elixir
opts = [
  database: "secure.db",
  encryption_key: "your-32-char-encryption-key-here"
]
{:ok, state} = EctoLibSql.connect(opts)
```

**Security notes:**
- Uses AES-256-CBC encryption
- Encryption key must be at least 32 characters
- Store keys in environment variables or secret managers
- Works with both local and replica modes

---

## Basic Operations

### INSERT

```elixir
# Single insert
{:ok, _, result, state} = EctoLibSql.handle_execute(
  "INSERT INTO users (name, email) VALUES (?, ?)",
  ["Bob", "bob@example.com"],
  [],
  state
)

# Get the inserted row ID
rowid = EctoLibSql.Native.get_last_insert_rowid(state)
IO.puts("Inserted row ID: #{rowid}")

# Check how many rows were affected
changes = EctoLibSql.Native.get_changes(state)
IO.puts("Rows affected: #{changes}")
```

### UPSERT (INSERT ... ON CONFLICT)

EctoLibSql supports all Ecto `on_conflict` options for upsert operations:

```elixir
# Ignore conflicts (do nothing on duplicate key)
{:ok, user} = Repo.insert(changeset,
  on_conflict: :nothing,
  conflict_target: [:email]
)

# Replace all fields on conflict
{:ok, user} = Repo.insert(changeset,
  on_conflict: :replace_all,
  conflict_target: [:email]
)

# Replace specific fields only
{:ok, user} = Repo.insert(changeset,
  on_conflict: {:replace, [:name, :updated_at]},
  conflict_target: [:email]
)

# Replace all except specific fields
{:ok, user} = Repo.insert(changeset,
  on_conflict: {:replace_all_except, [:id, :inserted_at]},
  conflict_target: [:email]
)

# Query-based update with keyword list syntax
{:ok, user} = Repo.insert(changeset,
  on_conflict: [set: [name: "Updated Name", updated_at: DateTime.utc_now()]],
  conflict_target: [:email]
)

# Increment counter on conflict
{:ok, counter} = Repo.insert(counter_changeset,
  on_conflict: [inc: [count: 1]],
  conflict_target: [:key]
)
```

**Notes:**
- `:conflict_target` is required for LibSQL/SQLite (unlike PostgreSQL)
- Composite unique indexes work: `conflict_target: [:slug, :parent_slug]`
- Named constraints (`ON CONFLICT ON CONSTRAINT name`) are not supported

### SELECT

```elixir
# Simple select
{:ok, _, result, state} = EctoLibSql.handle_execute(
  "SELECT * FROM users",
  [],
  [],
  state
)

Enum.each(result.rows, fn [id, name, email] ->
  IO.puts("User #{id}: #{name} (#{email})")
end)

# Parameterised select
{:ok, _, result, state} = EctoLibSql.handle_execute(
  "SELECT name, email FROM users WHERE id = ?",
  [1],
  [],
  state
)
```

### UPDATE

```elixir
{:ok, _, result, state} = EctoLibSql.handle_execute(
  "UPDATE users SET email = ? WHERE name = ?",
  ["newemail@example.com", "Alice"],
  [],
  state
)

changes = EctoLibSql.Native.get_changes(state)
IO.puts("Updated #{changes} rows")
```

### DELETE

```elixir
{:ok, _, result, state} = EctoLibSql.handle_execute(
  "DELETE FROM users WHERE id = ?",
  [1],
  [],
  state
)

changes = EctoLibSql.Native.get_changes(state)
IO.puts("Deleted #{changes} rows")
```

---

## Advanced Features

### Transactions

#### Basic Transactions

```elixir
# Begin transaction
{:ok, :begin, state} = EctoLibSql.handle_begin([], state)

# Execute operations
{:ok, _, _, state} = EctoLibSql.handle_execute(
  "INSERT INTO users (name) VALUES (?)",
  ["Charlie"],
  [],
  state
)

{:ok, _, _, state} = EctoLibSql.handle_execute(
  "UPDATE accounts SET balance = balance - 100 WHERE user = ?",
  ["Charlie"],
  [],
  state
)

# Commit
{:ok, _, state} = EctoLibSql.handle_commit([], state)
```

#### Transaction Rollback

```elixir
{:ok, :begin, state} = EctoLibSql.handle_begin([], state)

{:ok, _, _, state} = EctoLibSql.handle_execute(
  "INSERT INTO users (name) VALUES (?)",
  ["Invalid User"],
  [],
  state
)

# Something went wrong, rollback
{:ok, _, state} = EctoLibSql.handle_rollback([], state)
```

#### Transaction Behaviours

Control locking and concurrency with transaction behaviours:

```elixir
# DEFERRED (default) - locks acquired on first write
{:ok, state} = EctoLibSql.Native.begin(state, behavior: :deferred)

# IMMEDIATE - acquires write lock immediately
{:ok, state} = EctoLibSql.Native.begin(state, behavior: :immediate)

# EXCLUSIVE - exclusive lock, blocks all other connections
{:ok, state} = EctoLibSql.Native.begin(state, behavior: :exclusive)

# READ_ONLY - read-only transaction (no locks)
{:ok, state} = EctoLibSql.Native.begin(state, behavior: :read_only)
```

**When to use each behaviour:**

- **DEFERRED**: General-purpose transactions, low contention
- **IMMEDIATE**: Write-heavy workloads, prevents writer starvation
- **EXCLUSIVE**: Bulk operations, database migrations
- **READ_ONLY**: Analytics queries, reports, consistency snapshots

#### Error Handling in Transactions

```elixir
defmodule MyApp.Transfer do
  def transfer_funds(from_user, to_user, amount, state) do
    with {:ok, :begin, state} <- EctoLibSql.handle_begin([], state),
         {:ok, _, _, state} <- debit_account(from_user, amount, state),
         {:ok, _, _, state} <- credit_account(to_user, amount, state),
         {:ok, _, state} <- EctoLibSql.handle_commit([], state) do
      {:ok, state}
    else
      {:error, reason, state} ->
        EctoLibSql.handle_rollback([], state)
        {:error, reason}
    end
  end

  defp debit_account(user, amount, state) do
    EctoLibSql.handle_execute(
      "UPDATE accounts SET balance = balance - ? WHERE user = ? AND balance >= ?",
      [amount, user, amount],
      [],
      state
    )
  end

  defp credit_account(user, amount, state) do
    EctoLibSql.handle_execute(
      "UPDATE accounts SET balance = balance + ? WHERE user = ?",
      [amount, user],
      [],
      state
    )
  end
end
```

#### Savepoints (Nested Transactions)

Savepoints enable partial rollback within a transaction, perfect for error recovery patterns:

```elixir
# Begin transaction
{:ok, :begin, state} = EctoLibSql.handle_begin([], state)

# Create savepoint
{:ok, state} = EctoLibSql.Native.create_savepoint(state, "sp1")

{:ok, _, _, state} = EctoLibSql.handle_execute(
  "INSERT INTO users (name) VALUES (?)",
  ["Alice"],
  [],
  state
)

# If something goes wrong, rollback to savepoint (transaction stays active)
{:ok, state} = EctoLibSql.Native.rollback_to_savepoint_by_name(state, "sp1")

# Or release savepoint to commit its changes
{:ok, state} = EctoLibSql.Native.release_savepoint_by_name(state, "sp1")

# Commit the whole transaction
{:ok, _, state} = EctoLibSql.handle_commit([], state)
```

**Use case - Batch import with error recovery:**

```elixir
{:ok, :begin, state} = EctoLibSql.handle_begin([], state)

Enum.reduce(records, state, fn record, state ->
  # Create savepoint for this record
  {:ok, state} = EctoLibSql.Native.create_savepoint(state, "record_#{record.id}")
  
  case insert_record(record, state) do
    {:ok, _, _, state} ->
      # Success - release savepoint
      {:ok, state} = EctoLibSql.Native.release_savepoint_by_name(state, "record_#{record.id}")
      state
    {:error, _, _, state} ->
      # Failure - rollback this record, continue with others
      {:ok, state} = EctoLibSql.Native.rollback_to_savepoint_by_name(state, "record_#{record.id}")
      Logger.warn("Failed to import record #{record.id}")
      state
  end
end)

{:ok, _, state} = EctoLibSql.handle_commit([], state)
```

### Prepared Statements

Prepared statements offer significant performance improvements for repeated queries and prevent SQL injection. As of v0.7.0, statement caching is automatic and highly optimised. Named parameters provide flexible parameter binding with three SQLite syntaxes.

#### Named Parameters

SQLite supports three named parameter syntaxes for more readable and maintainable queries:

```elixir
# Syntax 1: Colon prefix (:name)
"SELECT * FROM users WHERE email = :email AND status = :status"

# Syntax 2: At-sign prefix (@name)
"SELECT * FROM users WHERE email = @email AND status = @status"

# Syntax 3: Dollar sign prefix ($name)
"SELECT * FROM users WHERE email = $email AND status = $status"
```

Execute with map-based parameters:

```elixir
# Prepared statement with named parameters
{:ok, stmt_id} = EctoLibSql.Native.prepare(
  state,
  "SELECT * FROM users WHERE email = :email AND status = :status"
)

{:ok, result} = EctoLibSql.Native.query_stmt(
  state,
  stmt_id,
  %{"email" => "alice@example.com", "status" => "active"}
)
```

Direct execution with named parameters:

```elixir
# INSERT with named parameters
{:ok, _, _, state} = EctoLibSql.handle_execute(
  "INSERT INTO users (name, email, age) VALUES (:name, :email, :age)",
  %{"name" => "Alice", "email" => "alice@example.com", "age" => 30},
  [],
  state
)

# UPDATE with named parameters
{:ok, _, _, state} = EctoLibSql.handle_execute(
  "UPDATE users SET status = :status, updated_at = :now WHERE id = :user_id",
  %{"status" => "inactive", "now" => DateTime.utc_now(), "user_id" => 123},
  [],
  state
)

# DELETE with named parameters
{:ok, _, _, state} = EctoLibSql.handle_execute(
  "DELETE FROM users WHERE id = :user_id AND email = :email",
  %{"user_id" => 123, "email" => "alice@example.com"},
  [],
  state
)
```

Named parameters in transactions:

```elixir
{:ok, :begin, state} = EctoLibSql.handle_begin([], state)

{:ok, _, _, state} = EctoLibSql.handle_execute(
  """
  INSERT INTO users (name, email) VALUES (:name, :email)
  """,
  %{"name" => "Alice", "email" => "alice@example.com"},
  [],
  state
)

{:ok, _, _, state} = EctoLibSql.handle_execute(
  "UPDATE users SET verified = 1 WHERE email = :email",
  %{"email" => "alice@example.com"},
  [],
  state
)

{:ok, _, state} = EctoLibSql.handle_commit([], state)
```

**Benefits:**
- **Readability**: Clear parameter names make queries self-documenting
- **Maintainability**: Easier to refactor when parameter names are explicit
- **Type safety**: Parameter validation can check required parameters upfront
- **Flexibility**: Use any of three SQLite syntaxes interchangeably
- **Prevention**: Prevents SQL injection attacks through proper parameter binding

**Backward Compatibility:**
Positional parameters (`?`) still work unchanged:

```elixir
# Positional parameters still work
{:ok, _, result, state} = EctoLibSql.handle_execute(
  "SELECT * FROM users WHERE email = ? AND status = ?",
  ["alice@example.com", "active"],
  [],
  state
)

# Named and positional can coexist in separate queries within the same codebase
```

**Avoiding Mixed Syntax:**
While SQLite technically permits mixing positional (`?`) and named (`:name`) parameters in a single statement, this is discouraged. Named parameters receive implicit numeric indices which can conflict with positional parameters, leading to unexpected binding order. This adapter's map-based approach naturally avoids this issue—pass a list for positional queries, or a map for named queries, but don't mix within a single statement.

#### How Statement Caching Works

Prepared statements are now cached internally after preparation:
- **First call**: `prepare/2` compiles the statement and caches it
- **Subsequent calls**: Cached statement is reused with `.reset()` to clear bindings
- **Performance**: ~10-15x faster than unprepared queries for repeated execution

```elixir
# Prepare the statement (compiled and cached internally)
{:ok, stmt_id} = EctoLibSql.Native.prepare(
  state,
  "SELECT * FROM users WHERE email = ?"
)

# Cached statement executed with fresh bindings each time
{:ok, result1} = EctoLibSql.Native.query_stmt(state, stmt_id, ["alice@example.com"])
{:ok, result2} = EctoLibSql.Native.query_stmt(state, stmt_id, ["bob@example.com"])
{:ok, result3} = EctoLibSql.Native.query_stmt(state, stmt_id, ["charlie@example.com"])

# Bindings are automatically cleared between calls - no manual cleanup needed

# Clean up when done
:ok = EctoLibSql.Native.close_stmt(stmt_id)
```

#### Performance Comparison

```elixir
defmodule MyApp.PerfTest do
  # ❌ Slow: Unprepared query executed 100 times (~2.5ms)
  def slow_lookup(state, emails) do
    Enum.each(emails, fn email ->
      {:ok, _, result, _} = EctoLibSql.handle_execute(
        "SELECT * FROM users WHERE email = ?",
        [email],
        [],
        state
      )
      IO.inspect(result)
    end)
  end

  # ✅ Fast: Prepared statement cached and reused (~330µs)
  def fast_lookup(state, emails) do
    {:ok, stmt_id} = EctoLibSql.Native.prepare(
      state,
      "SELECT * FROM users WHERE email = ?"
    )

    Enum.each(emails, fn email ->
      {:ok, result} = EctoLibSql.Native.query_stmt(state, stmt_id, [email])
      IO.inspect(result)
    end)

    EctoLibSql.Native.close_stmt(stmt_id)
  end
end
```

#### Prepared Statements with INSERT/UPDATE/DELETE

```elixir
# Prepare an INSERT statement
{:ok, stmt_id} = EctoLibSql.Native.prepare(
  state,
  "INSERT INTO users (name, email) VALUES (?, ?)"
)

# Execute multiple times with different parameters
# (SQL is re-supplied for sync detection; statement_id reuses the cached statement)
{:ok, rows1} = EctoLibSql.Native.execute_stmt(
  state,
  stmt_id,
  "INSERT INTO users (name, email) VALUES (?, ?)", # Required for sync detection
  ["Alice", "alice@example.com"]
)
IO.puts("Inserted #{rows1} rows")

{:ok, rows2} = EctoLibSql.Native.execute_stmt(
  state,
  stmt_id,
  "INSERT INTO users (name, email) VALUES (?, ?)",
  ["Bob", "bob@example.com"]
)
IO.puts("Inserted #{rows2} rows")

# Clean up
:ok = EctoLibSql.Native.close_stmt(stmt_id)
```

#### Statement Introspection (Query Structure Inspection)

Inspect prepared statement structure before execution (v0.7.0+):

```elixir
# Prepare a statement
{:ok, stmt_id} = EctoLibSql.Native.prepare(
  state,
  "SELECT id, name, email, created_at FROM users WHERE id > ?"
)

# Get parameter count (how many ? placeholders)
{:ok, param_count} = EctoLibSql.Native.stmt_parameter_count(state, stmt_id)
IO.puts("Statement expects #{param_count} parameter(s)")  # Prints: 1

# Get column count (how many columns in result set)
{:ok, col_count} = EctoLibSql.Native.stmt_column_count(state, stmt_id)
IO.puts("Result will have #{col_count} column(s)")  # Prints: 4

# Get column names
col_names =
  Enum.map(0..(col_count - 1), fn i ->
    {:ok, name} = EctoLibSql.Native.stmt_column_name(state, stmt_id, i)
    name
  end)
IO.inspect(col_names)  # Prints: ["id", "name", "email", "created_at"]

:ok = EctoLibSql.Native.close_stmt(stmt_id)
```

#### Prepared Statement Best Practices

```elixir
defmodule MyApp.UserRepository do
  def setup(state) do
    # Prepare commonly used statements at startup
    {:ok, find_by_email} = EctoLibSql.Native.prepare(
      state,
      "SELECT * FROM users WHERE email = ?"
    )

    {:ok, insert_user} = EctoLibSql.Native.prepare(
      state,
      "INSERT INTO users (name, email) VALUES (?, ?)"
    )

    {:ok, update_user} = EctoLibSql.Native.prepare(
      state,
      "UPDATE users SET name = ?, email = ? WHERE id = ?"
    )

    %{
      find_by_email: find_by_email,
      insert_user: insert_user,
      update_user: update_user,
      state: state
    }
  end

  def find_by_email(repo, email) do
    EctoLibSql.Native.query_stmt(repo.state, repo.find_by_email, [email])
  end

  def insert(repo, name, email) do
    EctoLibSql.Native.execute_stmt(
      repo.state,
      repo.insert_user,
      "INSERT INTO users (name, email) VALUES (?, ?)",
      [name, email]
    )
  end

  def cleanup(repo) do
    EctoLibSql.Native.close_stmt(repo.find_by_email)
    EctoLibSql.Native.close_stmt(repo.insert_user)
    EctoLibSql.Native.close_stmt(repo.update_user)
  end
end
```

### Batch Operations

Execute multiple statements efficiently with reduced roundtrips.

#### Non-Transactional Batch

Each statement executes independently. If one fails, others still complete.

```elixir
statements = [
  {"INSERT INTO users (name, email) VALUES (?, ?)", ["Alice", "alice@example.com"]},
  {"INSERT INTO users (name, email) VALUES (?, ?)", ["Bob", "bob@example.com"]},
  {"INSERT INTO users (name, email) VALUES (?, ?)", ["Charlie", "charlie@example.com"]},
  {"SELECT COUNT(*) FROM users", []}
]

{:ok, results} = EctoLibSql.Native.batch(state, statements)

Enum.each(results, fn result ->
  IO.inspect(result)
end)
```

#### Transactional Batch

All statements execute atomically. If any fails, all are rolled back.

```elixir
statements = [
  {"UPDATE accounts SET balance = balance - 100 WHERE user = ?", ["Alice"]},
  {"UPDATE accounts SET balance = balance + 100 WHERE user = ?", ["Bob"]},
  {"INSERT INTO transactions (from_user, to_user, amount) VALUES (?, ?, ?)",
   ["Alice", "Bob", 100]}
]

{:ok, results} = EctoLibSql.Native.batch_transactional(state, statements)
```

#### Raw SQL Batch Execution

Execute multiple SQL statements as a single string (v0.7.0+):

```elixir
# Non-transactional: each statement executes independently
sql = """
CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);
INSERT INTO users (name) VALUES ('Alice');
INSERT INTO users (name) VALUES ('Bob');
"""

{:ok, _} = EctoLibSql.Native.execute_batch_sql(state, sql)

# Transactional: all-or-nothing execution
sql = """
INSERT INTO users (name) VALUES ('Charlie');
INSERT INTO users (name) VALUES ('David');
UPDATE users SET name = 'Chuck' WHERE name = 'Charlie';
"""

{:ok, _} = EctoLibSql.Native.execute_transactional_batch_sql(state, sql)
```

#### Bulk Insert Example

```elixir
defmodule MyApp.BulkImporter do
  def import_users(csv_path, state) do
    statements =
      csv_path
      |> File.stream!()
      |> CSV.decode!(headers: true)
      |> Enum.map(fn %{"name" => name, "email" => email} ->
        {"INSERT INTO users (name, email) VALUES (?, ?)", [name, email]}
      end)
      |> Enum.to_list()

    case EctoLibSql.Native.batch_transactional(state, statements) do
      {:ok, results} ->
        IO.puts("Imported #{length(results)} users")
        {:ok, length(results)}

      {:error, reason} ->
        IO.puts("Import failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
```

### Cursor Streaming

For large result sets, use cursors to stream data without loading everything into memory.

#### Basic Cursor Usage

```elixir
# Start a DBConnection
{:ok, conn} = DBConnection.start_link(EctoLibSql, database: "myapp.db")

# Create a stream
stream = DBConnection.stream(
  conn,
  %EctoLibSql.Query{statement: "SELECT * FROM large_table"},
  []
)

# Process in chunks
stream
|> Enum.each(fn %EctoLibSql.Result{rows: rows, num_rows: count} ->
  IO.puts("Processing batch of #{count} rows")
  Enum.each(rows, &process_row/1)
end)
```

#### Cursor with Custom Batch Size

```elixir
# Fetch 100 rows at a time instead of default 500
stream = DBConnection.stream(
  conn,
  %EctoLibSql.Query{statement: "SELECT * FROM large_table"},
  [],
  max_rows: 100
)

stream
|> Stream.map(fn result -> result.rows end)
|> Stream.concat()
|> Stream.chunk_every(1000)
|> Enum.each(fn chunk ->
  # Process 1000 rows at a time
  MyApp.process_batch(chunk)
end)
```

#### Memory-Efficient Data Export

```elixir
defmodule MyApp.Exporter do
  def export_to_json(conn, output_path) do
    file = File.open!(output_path, [:write])

    DBConnection.stream(
      conn,
      %EctoLibSql.Query{statement: "SELECT * FROM users"},
      [],
      max_rows: 1000
    )
    |> Stream.flat_map(fn %EctoLibSql.Result{rows: rows} -> rows end)
    |> Stream.map(fn [id, name, email] ->
      Jason.encode!(%{id: id, name: name, email: email})
    end)
    |> Stream.intersperse("\n")
    |> Enum.into(file)

    File.close(file)
  end
end
```

### Vector Search

EctoLibSql includes built-in support for vector similarity search, perfect for AI/ML applications.

#### Creating Vector Tables

```elixir
# Create a table with a 1536-dimensional vector column (OpenAI embeddings)
vector_col = EctoLibSql.Native.vector_type(1536, :f32)

{:ok, _, _, state} = EctoLibSql.handle_execute(
  """
  CREATE TABLE documents (
    id INTEGER PRIMARY KEY,
    content TEXT,
    embedding #{vector_col}
  )
  """,
  [],
  [],
  state
)
```

#### Inserting Vectors

```elixir
# Get embedding from your AI model
embedding = MyApp.OpenAI.get_embedding("Hello, world!")
# Returns: [0.123, -0.456, 0.789, ...]

# Convert to vector format
vec = EctoLibSql.Native.vector(embedding)

# Insert
{:ok, _, _, state} = EctoLibSql.handle_execute(
  "INSERT INTO documents (content, embedding) VALUES (?, vector(?))",
  ["Hello, world!", vec],
  [],
  state
)
```

#### Similarity Search

```elixir
# Query vector
query_text = "greeting messages"
query_embedding = MyApp.OpenAI.get_embedding(query_text)

# Build distance SQL
distance_sql = EctoLibSql.Native.vector_distance_cos("embedding", query_embedding)

# Find most similar documents
{:ok, _, result, state} = EctoLibSql.handle_execute(
  """
  SELECT id, content, #{distance_sql} as distance
  FROM documents
  ORDER BY distance
  LIMIT 10
  """,
  [],
  [],
  state
)

Enum.each(result.rows, fn [id, content, distance] ->
  IO.puts("Document #{id}: #{content} (distance: #{distance})")
end)
```

#### Complete RAG Example

```elixir
defmodule MyApp.RAG do
  @embedding_dimensions 1536

  def setup(state) do
    vector_col = EctoLibSql.Native.vector_type(@embedding_dimensions, :f32)

    EctoLibSql.handle_execute(
      """
      CREATE TABLE IF NOT EXISTS knowledge_base (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        source TEXT,
        content TEXT,
        embedding #{vector_col},
        created_at INTEGER
      )
      """,
      [],
      [],
      state
    )
  end

  def add_document(state, source, content) do
    # Get embedding from OpenAI
    embedding = get_embedding(content)
    vec = EctoLibSql.Native.vector(embedding)

    EctoLibSql.handle_execute(
      """
      INSERT INTO knowledge_base (source, content, embedding, created_at)
      VALUES (?, ?, vector(?), ?)
      """,
      [source, content, vec, System.system_time(:second)],
      [],
      state
    )
  end

  def search(state, query, limit \\ 5) do
    query_embedding = get_embedding(query)
    distance_sql = EctoLibSql.Native.vector_distance_cos("embedding", query_embedding)

    {:ok, _, result, _} = EctoLibSql.handle_execute(
      """
      SELECT source, content, #{distance_sql} as relevance
      FROM knowledge_base
      ORDER BY relevance
      LIMIT ?
      """,
      [limit],
      [],
      state
    )

    Enum.map(result.rows, fn [source, content, relevance] ->
      %{source: source, content: content, relevance: relevance}
    end)
  end

  defp get_embedding(text) do
    # Your OpenAI API call here
    MyApp.OpenAI.create_embedding(text)
  end
end
```

#### Vector Search with Metadata Filtering

```elixir
# Create table with metadata
vector_col = EctoLibSql.Native.vector_type(384, :f32)

{:ok, _, _, state} = EctoLibSql.handle_execute(
  """
  CREATE TABLE products (
    id INTEGER PRIMARY KEY,
    name TEXT,
    category TEXT,
    price REAL,
    description_embedding #{vector_col}
  )
  """,
  [],
  [],
  state
)

# Search within a category
query_embedding = get_embedding("comfortable running shoes")
distance_sql = EctoLibSql.Native.vector_distance_cos("description_embedding", query_embedding)

{:ok, _, result, state} = EctoLibSql.handle_execute(
  """
  SELECT name, price, #{distance_sql} as similarity
  FROM products
  WHERE category = ? AND price <= ?
  ORDER BY similarity
  LIMIT 10
  """,
  ["shoes", 150.0],
  [],
  state
)
```

### Connection Management

Control connection behaviour and performance with these utilities (v0.7.0+):

#### Busy Timeout

Configure how long to wait when the database is locked:

```elixir
# Set timeout to 10 seconds (default is 5 seconds)
{:ok, state} = EctoLibSql.Native.busy_timeout(state, 10_000)

# Now queries will wait up to 10s for locks to release
{:ok, _, result, state} = EctoLibSql.handle_execute(
  "INSERT INTO users (name) VALUES (?)",
  ["Alice"],
  [],
  state
)
```

#### Reset Connection

Reset connection state without closing it:

```elixir
# Reset clears prepared statements, releases locks, rolls back transactions
{:ok, state} = EctoLibSql.Native.reset(state)
```

#### Interrupt Long-Running Queries

Cancel a query that's taking too long:

```elixir
# In one process
Task.async(fn ->
  EctoLibSql.handle_execute("SELECT * FROM huge_table", [], [], state)
end)

# In another process, interrupt it
:ok = EctoLibSql.Native.interrupt(state)
```

### PRAGMA Configuration

Configure SQLite database parameters with the `EctoLibSql.Pragma` module (v0.7.0+):

#### Foreign Keys

```elixir
# Enable foreign key constraints
{:ok, state} = EctoLibSql.Pragma.enable_foreign_keys(state)

# Check if enabled
{:ok, enabled} = EctoLibSql.Pragma.foreign_keys(state)
IO.inspect(enabled)  # true
```

#### Journal Mode

```elixir
# Set to WAL mode for better concurrency
{:ok, state} = EctoLibSql.Pragma.set_journal_mode(state, :wal)

# Check current mode
{:ok, mode} = EctoLibSql.Pragma.journal_mode(state)
IO.inspect(mode)  # :wal
```

#### Cache Size

```elixir
# Set cache to 10MB (negative values = KB)
{:ok, state} = EctoLibSql.Pragma.set_cache_size(state, -10_000)

# Or use pages (positive values)
{:ok, state} = EctoLibSql.Pragma.set_cache_size(state, 2000)
```

#### Synchronous Level

```elixir
# Set synchronous mode (trade durability for speed)
{:ok, state} = EctoLibSql.Pragma.set_synchronous(state, :normal)

# Options: :off, :normal, :full, :extra
```

#### Table Introspection

```elixir
# Get table structure
{:ok, columns} = EctoLibSql.Pragma.table_info(state, "users")
Enum.each(columns, fn col ->
  IO.inspect(col)  # %{name: "id", type: "INTEGER", ...}
end)

# List all tables
{:ok, tables} = EctoLibSql.Pragma.table_list(state)
IO.inspect(tables)  # ["users", "posts", "sqlite_sequence"]
```

#### User Version (Schema Versioning)

```elixir
# Set schema version
{:ok, state} = EctoLibSql.Pragma.set_user_version(state, 5)

# Get current version
{:ok, version} = EctoLibSql.Pragma.user_version(state)
IO.inspect(version)  # 5
```

### Encryption

Protect sensitive data with AES-256-CBC encryption at rest.

#### Local Encrypted Database

```elixir
opts = [
  database: "secure.db",
  encryption_key: System.get_env("DB_ENCRYPTION_KEY")
]

{:ok, state} = EctoLibSql.connect(opts)

# Use normally - encryption is transparent
{:ok, _, _, state} = EctoLibSql.handle_execute(
  "INSERT INTO secrets (data) VALUES (?)",
  ["sensitive information"],
  [],
  state
)
```

#### Encrypted Remote Replica

```elixir
opts = [
  uri: "libsql://my-database.turso.io",
  auth_token: System.get_env("TURSO_AUTH_TOKEN"),
  database: "encrypted_replica.db",
  encryption_key: System.get_env("DB_ENCRYPTION_KEY"),
  sync: true
]

{:ok, state} = EctoLibSql.connect(opts)
```

#### Key Management Best Practices

```elixir
defmodule MyApp.DatabaseConfig do
  def get_encryption_key do
    # Option 1: Environment variable
    key = System.get_env("DB_ENCRYPTION_KEY")

    # Option 2: Secret management service (recommended for production)
    # key = MyApp.SecretManager.get_secret("database-encryption-key")

    # Option 3: Vault/KMS
    # key = MyApp.Vault.get_key("database-encryption")

    if byte_size(key) < 32 do
      raise "Encryption key must be at least 32 characters"
    end

    key
  end

  def connection_opts do
    [
      database: "secure.db",
      encryption_key: get_encryption_key()
    ]
  end
end

# Usage
{:ok, state} = EctoLibSql.connect(MyApp.DatabaseConfig.connection_opts())
```

### JSON Schema Helpers

EctoLibSql provides `EctoLibSql.JSON` module with comprehensive helpers for working with JSON and JSONB data. LibSQL 3.45.1 has JSON1 built into the core with support for both text JSON and efficient JSONB binary format.

#### JSON Functions

```elixir
alias EctoLibSql.JSON

# Extract values from JSON
{:ok, theme} = JSON.extract(state, ~s({"user":{"prefs":{"theme":"dark"}}}), "$.user.prefs.theme")
# Returns: {:ok, "dark"}

# Check JSON type
{:ok, type} = JSON.type(state, ~s({"count":42}), "$.count")
# Returns: {:ok, "integer"}

# Validate JSON
{:ok, true} = JSON.is_valid(state, ~s({"valid":true}))
{:ok, false} = JSON.is_valid(state, "not json")

# Create JSON structures
{:ok, array} = JSON.array(state, [1, 2.5, "hello", nil])
# Returns: {:ok, "[1,2.5,\"hello\",null]"}

{:ok, obj} = JSON.object(state, ["name", "Alice", "age", 30, "active", true])
# Returns: {:ok, "{\"name\":\"Alice\",\"age\":30,\"active\":true}"}
```

#### Iterating Over JSON

```elixir
# Iterate over array elements or object members
{:ok, items} = JSON.each(state, ~s([1,2,3]), "$")
# Returns: {:ok, [{0, 1, "integer"}, {1, 2, "integer"}, {2, 3, "integer"}]}

# Recursively iterate all values (flattening)
{:ok, tree} = JSON.tree(state, ~s({"a":{"b":1},"c":[2,3]}), "$")
# Returns: all nested values with their full paths
```

#### JSONB Binary Format

JSONB is a more efficient binary encoding of JSON with 5-10% smaller size and faster processing:

```elixir
# Convert to binary JSONB format
json_string = ~s({"name":"Alice","age":30})
{:ok, jsonb_binary} = JSON.convert(state, json_string, :jsonb)

# All JSON functions work with both text and JSONB
{:ok, value} = JSON.extract(state, jsonb_binary, "$.name")
# Transparently works with binary format

# Convert back to text JSON
{:ok, canonical} = JSON.convert(state, json_string, :json)
```

#### Arrow Operators (-> and ->>)

The `->` and `->>` operators provide concise syntax for JSON access in queries:

```elixir
# -> returns JSON (always)
fragment = JSON.arrow_fragment("settings", "theme")
# Returns: "settings -> 'theme'"

# ->> returns SQL type (text/int/real/null)
fragment = JSON.arrow_fragment("settings", "theme", :double_arrow)
# Returns: "settings ->> 'theme'"

# Use in Ecto queries - Option 1: Using the helper function
arrow_sql = JSON.arrow_fragment("data", "active", :double_arrow)
from u in User,
  where: fragment(arrow_sql <> " = ?", true)

# Option 2: Direct inline SQL (simpler approach)
from u in User,
  where: fragment("data ->> 'active' = ?", true)
```

#### Ecto Integration

JSON helpers work seamlessly with Ecto:

```elixir
defmodule MyApp.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :name, :string
    field :settings, :map  # Stored as JSON/JSONB
    timestamps()
  end
end

# In your repository context
import Ecto.Query

# Query with JSON extraction
from u in User,
  where: fragment("json_extract(?, ?) = ?", u.settings, "$.theme", "dark"),
  select: u.name

# Or using the helpers - Option 1: Arrow fragment helper
arrow_sql = JSON.arrow_fragment("settings", "theme", :double_arrow)
from u in User,
  where: fragment(arrow_sql <> " = ?", "dark")

# Option 2: Direct inline SQL (simpler for static fields)
from u in User,
  where: fragment("settings ->> 'theme' = ?", "dark")

# Update JSON fields
from u in User,
  where: u.id == ^user_id,
  update: [set: [settings: fragment("json_set(?, ?, ?)", u.settings, "$.theme", "light")]]
```

#### JSON Modification Functions

Create, update, and manipulate JSON structures:

```elixir
# Quote a value for JSON
{:ok, quoted} = JSON.json_quote(state, "hello \"world\"")
# Returns: {:ok, "\"hello \\\"world\\\"\""}

# Get JSON array/object length (SQLite 3.9.0+)
{:ok, len} = JSON.json_length(state, ~s([1,2,3,4,5]))
# Returns: {:ok, 5}

# Get JSON structure depth (SQLite 3.9.0+)
{:ok, depth} = JSON.depth(state, ~s({"a":{"b":{"c":1}}}))
# Returns: {:ok, 4}

# Set a value (creates path if not exists)
{:ok, json} = JSON.set(state, ~s({"a":1}), "$.b", 2)
# Returns: {:ok, "{\"a\":1,\"b\":2}"}

# Replace a value (only if path exists)
{:ok, json} = JSON.replace(state, ~s({"a":1,"b":2}), "$.a", 10)
# Returns: {:ok, "{\"a\":10,\"b\":2}"}

# Insert without replacing
{:ok, json} = JSON.insert(state, ~s({"a":1}), "$.b", 2)
# Returns: {:ok, "{\"a\":1,\"b\":2}"}

# Remove keys/paths
{:ok, json} = JSON.remove(state, ~s({"a":1,"b":2,"c":3}), "$.b")
# Returns: {:ok, "{\"a\":1,\"c\":3}"}

# Remove multiple paths
{:ok, json} = JSON.remove(state, ~s({"a":1,"b":2,"c":3}), ["$.a", "$.c"])
# Returns: {:ok, "{\"b\":2}"}

# Apply a JSON Merge Patch (RFC 7396)
# Keys in patch are object keys, not JSON paths
{:ok, json} = JSON.patch(state, ~s({"a":1,"b":2}), ~s({"a":10,"c":3}))
# Returns: {:ok, "{\"a\":10,\"b\":2,\"c\":3}"}

# Remove a key by patching with null
{:ok, json} = JSON.patch(state, ~s({"a":1,"b":2,"c":3}), ~s({"b":null}))
# Returns: {:ok, "{\"a\":1,\"c\":3}"}

# Get all keys from a JSON object (SQLite 3.9.0+)
{:ok, keys} = JSON.keys(state, ~s({"name":"Alice","age":30}))
# Returns: {:ok, "[\"age\",\"name\"]"}  (sorted)
```

#### Real-World Example: Settings Management

```elixir
defmodule MyApp.UserPreferences do
  alias EctoLibSql.JSON

  def get_preference(state, settings_json, key_path) do
    JSON.extract(state, settings_json, "$.#{key_path}")
  end

  def set_preference(state, settings_json, key_path, value) do
    # Build JSON path from key path
    json_path = "$.#{key_path}"
    
    # Use JSON.set instead of raw SQL
    JSON.set(state, settings_json, json_path, value)
  end

  def update_theme(state, settings_json, theme) do
    JSON.set(state, settings_json, "$.theme", theme)
  end

  def toggle_notifications(state, settings_json) do
    # Get current value
    {:ok, current} = JSON.extract(state, settings_json, "$.notifications")
    new_value = not current
    
    # Update it
    JSON.set(state, settings_json, "$.notifications", new_value)
  end

  def remove_preference(state, settings_json, key_path) do
    json_path = "$.#{key_path}"
    JSON.remove(state, settings_json, json_path)
  end

  def validate_settings(state, settings_json) do
    JSON.is_valid(state, settings_json)
  end

  def get_structure_info(state, settings_json) do
    with {:ok, is_valid} <- JSON.is_valid(state, settings_json),
         {:ok, json_type} <- JSON.type(state, settings_json),
         {:ok, depth} <- JSON.depth(state, settings_json) do
      {:ok, %{valid: is_valid, type: json_type, depth: depth}}
    end
  end

  # Build settings from scratch
  def create_default_settings(state) do
    JSON.object(state, [
      "theme", "light",
      "notifications", true,
      "language", "en",
      "timezone", "UTC"
    ])
  end

  # Merge settings with defaults
  def merge_with_defaults(state, user_settings, defaults) do
    with {:ok, user_map} <- JSON.tree(state, user_settings),
         {:ok, defaults_map} <- JSON.tree(state, defaults) do
      # In practice, you'd merge these maps here
      {:ok, user_settings}
    end
  end
end

# Usage
{:ok, state} = EctoLibSql.connect(database: "app.db")
settings = ~s({"theme":"dark","notifications":true,"language":"es"})

# Get a preference
{:ok, theme} = MyApp.UserPreferences.get_preference(state, settings, "theme")
# Returns: {:ok, "dark"}

# Update a preference
{:ok, new_settings} = MyApp.UserPreferences.update_theme(state, settings, "light")

# Toggle notifications
{:ok, new_settings} = MyApp.UserPreferences.toggle_notifications(state, settings)

# Validate settings
{:ok, valid?} = MyApp.UserPreferences.validate_settings(state, settings)
# Returns: {:ok, true}

# Get structure info
{:ok, info} = MyApp.UserPreferences.get_structure_info(state, settings)
# Returns: {:ok, %{valid: true, type: "object", depth: 2}}
```

#### Comparison: Set vs Replace vs Insert vs Patch

The modification functions have different behaviors:

```elixir
json = ~s({"a":1,"b":2})

# SET: Creates or replaces any path (uses JSON paths like "$.key")
{:ok, result} = JSON.set(state, json, "$.c", 3)
# Result: {"a":1,"b":2,"c":3}

{:ok, result} = JSON.set(state, json, "$.a", 100)
# Result: {"a":100,"b":2}

# REPLACE: Only updates existing paths, ignores new paths (uses JSON paths)
{:ok, result} = JSON.replace(state, json, "$.c", 3)
# Result: {"a":1,"b":2}  (c not added)

{:ok, result} = JSON.replace(state, json, "$.a", 100)
# Result: {"a":100,"b":2}  (existing path updated)

# INSERT: Adds new values without replacing existing ones (uses JSON paths)
{:ok, result} = JSON.insert(state, json, "$.c", 3)
# Result: {"a":1,"b":2,"c":3}

{:ok, result} = JSON.insert(state, json, "$.a", 100)
# Result: {"a":1,"b":2}  (existing path unchanged)

# PATCH: Applies JSON Merge Patch (RFC 7396) - keys are object keys, not paths
{:ok, result} = JSON.patch(state, json, ~s({"a":10,"c":3}))
# Result: {"a":10,"b":2,"c":3}

# Use null to remove keys
{:ok, result} = JSON.patch(state, json, ~s({"b":null}))
# Result: {"a":1}
```

**When to use each function:**
- **SET/REPLACE/INSERT**: For path-based updates using JSON paths (e.g., "$.user.name")
- **PATCH**: For bulk top-level key updates (implements RFC 7396 JSON Merge Patch)

#### Performance Notes

- JSONB format reduces storage by 5-10% vs text JSON
- JSONB processes in less than half the CPU cycles
- All JSON functions accept both text and JSONB transparently
- For frequent extractions, consider denormalising commonly accessed fields
- Use `json_each()` and `json_tree()` for flattening/searching

---

## Ecto Integration

EctoLibSql provides a full Ecto adapter, making it seamless to use with Phoenix and Ecto-based applications. This enables you to use all Ecto features including schemas, migrations, queries, and associations.

### Quick Start with Ecto

#### 1. Installation

Add `ecto_libsql` to your dependencies (it already includes `ecto_sql`):

```elixir
def deps do
  [
    {:ecto_libsql, "~> 0.8.0"}
  ]
end
```

#### 2. Configure Your Repository

```elixir
# config/config.exs

# Local database (development)
config :my_app, MyApp.Repo,
  adapter: Ecto.Adapters.LibSql,
  database: "my_app_dev.db",
  pool_size: 5

# Remote Turso (cloud-only)
config :my_app, MyApp.Repo,
  adapter: Ecto.Adapters.LibSql,
  uri: "libsql://your-database.turso.io",
  auth_token: System.get_env("TURSO_AUTH_TOKEN")

# Remote Replica (RECOMMENDED for production)
config :my_app, MyApp.Repo,
  adapter: Ecto.Adapters.LibSql,
  database: "replica.db",
  uri: "libsql://your-database.turso.io",
  auth_token: System.get_env("TURSO_AUTH_TOKEN"),
  sync: true,
  pool_size: 10
```

#### 3. Define Your Repo

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.LibSql
end
```

### Schemas and Changesets

Define your data models using Ecto schemas:

```elixir
defmodule MyApp.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :name, :string
    field :email, :string
    field :age, :integer
    field :active, :boolean, default: true
    field :bio, :text

    has_many :posts, MyApp.Post

    timestamps()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:name, :email, :age, :active, :bio])
    |> validate_required([:name, :email])
    |> validate_format(:email, ~r/@/)
    |> unique_constraint(:email)
  end
end

defmodule MyApp.Post do
  use Ecto.Schema
  import Ecto.Changeset

  schema "posts" do
    field :title, :string
    field :body, :text
    field :published, :boolean, default: false
    field :view_count, :integer, default: 0

    belongs_to :user, MyApp.User

    timestamps()
  end

  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body, :published, :user_id])
    |> validate_required([:title, :body])
    |> foreign_key_constraint(:user_id)
  end
end
```

### Migrations

Create database migrations just like with PostgreSQL or MySQL:

```elixir
# priv/repo/migrations/20240101000000_create_users.exs
defmodule MyApp.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :name, :string, null: false
      add :email, :string, null: false
      add :age, :integer
      add :active, :boolean, default: true
      add :bio, :text

      timestamps()
    end

    create unique_index(:users, [:email])
    create index(:users, [:active])
  end
end

# priv/repo/migrations/20240101000001_create_posts.exs
defmodule MyApp.Repo.Migrations.CreatePosts do
  use Ecto.Migration

  def change do
    create table(:posts) do
      add :title, :string, null: false
      add :body, :text
      add :published, :boolean, default: false
      add :view_count, :integer, default: 0
      add :user_id, references(:users, on_delete: :delete_all)

      timestamps()
    end

    create index(:posts, [:user_id])
    create index(:posts, [:published])
  end
end
```

Run migrations:

```bash
mix ecto.create    # Create the database
mix ecto.migrate   # Run migrations
mix ecto.rollback  # Rollback last migration
```

#### STRICT Tables (Type Enforcement)

STRICT tables enforce strict type checking - columns must be one of the allowed SQLite types. This prevents accidental type mismatches and data corruption:

```elixir
# Create a STRICT table for type safety
defmodule MyApp.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users, strict: true) do
      add :id, :integer, primary_key: true
      add :name, :string, null: false
      add :email, :string, null: false
      add :age, :integer
      add :balance, :float, default: 0.0
      add :avatar, :binary
      add :is_active, :boolean, default: true

      timestamps()
    end

    create unique_index(:users, [:email])
  end
end
```

**Benefits:**
- **Type Safety**: Enforces that columns only accept their declared types (TEXT, INTEGER, REAL, BLOB, NULL)
- **Data Integrity**: Prevents accidental type coercion that could lead to bugs
- **Better Errors**: Clear error messages when incorrect types are inserted
- **Performance**: Can enable better query optimisation by knowing exact column types

**Allowed Types in STRICT Tables:**
- `INT`, `INTEGER` - Integer values only
- `TEXT` - Text values only
- `BLOB` - Binary data only
- `REAL` - Floating-point values only
- `NULL` - NULL values only (rarely used)

**Usage Examples:**

```elixir
# STRICT table with various types
create table(:products, strict: true) do
  add :sku, :string, null: false              # Must be TEXT
  add :name, :string, null: false             # Must be TEXT
  add :quantity, :integer, default: 0         # Must be INTEGER
  add :price, :float, null: false             # Must be REAL
  add :description, :text                     # Must be TEXT
  add :image_data, :binary                    # Must be BLOB
  add :published_at, :utc_datetime            # Stored as TEXT (ISO8601 format)
  timestamps()
end

# Combining STRICT with RANDOM ROWID
create table(:api_keys, options: [strict: true, random_rowid: true]) do
  add :user_id, references(:users, on_delete: :delete_all)  # INTEGER
  add :key, :string, null: false                            # TEXT
  add :secret, :string, null: false                         # TEXT
  add :last_used_at, :utc_datetime                          # TEXT
  timestamps()
end
```

**Restrictions:**
- STRICT is a libSQL/SQLite 3.37+ extension (not available in older versions)
- Type affinity is enforced: generic types like `TEXT(50)` or `DATE` are not allowed
- Dynamic type changes (e.g., storing integers in TEXT columns) will fail with type errors
- Standard SQLite does not support STRICT tables

**SQL Output:**
```sql
CREATE TABLE users (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  email TEXT NOT NULL,
  age INTEGER,
  balance REAL DEFAULT 0.0,
  avatar BLOB,
  is_active INTEGER DEFAULT 1,
  inserted_at TEXT,
  updated_at TEXT
) STRICT
```

**Error Example:**
```elixir
# This will fail on a STRICT table:
Repo.query!("INSERT INTO users (name, email, age) VALUES (?, ?, ?)",
  [123, "alice@example.com", "thirty"])  # ← age is string, not INTEGER
# Error: "Type mismatch" (SQLite enforces STRICT)
```

#### RANDOM ROWID Support (libSQL Extension)

For security and privacy, use RANDOM ROWID to generate pseudorandom row IDs instead of sequential integers:

```elixir
# Create table with random row IDs (prevents ID enumeration attacks)
defmodule MyApp.Repo.Migrations.CreateSessions do
  use Ecto.Migration

  def change do
    create table(:sessions, options: [random_rowid: true]) do
      add :token, :string, null: false
      add :user_id, references(:users, on_delete: :delete_all)
      add :expires_at, :utc_datetime

      timestamps()
    end

    create unique_index(:sessions, [:token])
  end
end
```

**Benefits:**
- **Security**: Prevents ID enumeration attacks (guessing valid IDs)
- **Privacy**: Doesn't leak business metrics through sequential IDs
- **Unpredictability**: Row IDs are pseudorandom, not sequential

**Usage:**
```elixir
# Basic usage
create table(:sessions, options: [random_rowid: true]) do
  add :token, :string
end

# With composite primary key
create table(:audit_log, options: [random_rowid: true]) do
  add :user_id, :integer, primary_key: true
  add :action_id, :integer, primary_key: true
  add :timestamp, :integer
end

# With IF NOT EXISTS
create_if_not_exists table(:sessions, options: [random_rowid: true]) do
  add :token, :string
end
```

**Restrictions:**
- Mutually exclusive with WITHOUT ROWID (per libSQL specification)
- Mutually exclusive with AUTOINCREMENT (per libSQL specification)
- LibSQL extension - not available in standard SQLite

**SQL Output:**
```sql
CREATE TABLE sessions (...) RANDOM ROWID
```

#### ALTER COLUMN Support (libSQL Extension)

LibSQL supports modifying column attributes with ALTER COLUMN (not available in standard SQLite):

```elixir
defmodule MyApp.Repo.Migrations.ModifyUserColumns do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # Change column type
      modify :age, :string, default: "0"

      # Add NOT NULL constraint
      modify :email, :string, null: false

      # Add DEFAULT value
      modify :status, :string, default: "active"

      # Add foreign key reference
      modify :team_id, references(:teams, on_delete: :nilify_all)
    end
  end
end
```

**Supported Modifications:**
- Type affinity changes (`:integer` → `:string`, etc.)
- NOT NULL constraints
- DEFAULT values
- CHECK constraints
- REFERENCES (foreign keys)

**Important Notes:**
- Changes only apply to **new or updated rows**
- Existing data is **not revalidated** or modified
- This is a **libSQL extension** - not available in standard SQLite

**SQL Output:**
```sql
ALTER TABLE users ALTER COLUMN age TO age TEXT DEFAULT '0'
ALTER TABLE users ALTER COLUMN email TO email TEXT NOT NULL
```

#### Generated/Computed Columns

SQLite 3.31+ and libSQL support GENERATED ALWAYS AS columns (computed columns). These are columns whose values are computed from an expression:

```elixir
defmodule MyApp.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :first_name, :string, null: false
      add :last_name, :string, null: false
      # Virtual generated column (computed on read, not stored)
      add :full_name, :string, generated: "first_name || ' ' || last_name"

      timestamps()
    end
  end
end
```

**Stored Generated Columns:**

Use `stored: true` to persist the computed value (updated automatically on insert/update):

```elixir
create table(:products) do
  add :price, :float, null: false
  add :quantity, :integer, null: false
  # Stored - value is written to disk
  add :total_value, :float, generated: "price * quantity", stored: true

  timestamps()
end
```

**Options:**
- `generated: "expression"` - SQL expression to compute the column value
- `stored: true` - Store the computed value (default is VIRTUAL/not stored)

**Constraints (SQLite limitations):**
- Generated columns **cannot** have a DEFAULT value
- Generated columns **cannot** be part of a PRIMARY KEY
- The expression must be deterministic (no RANDOM(), CURRENT_TIME, etc.)
- STORED generated columns can be indexed; VIRTUAL columns cannot

**SQL Output:**
```sql
-- Virtual (default)
CREATE TABLE users (
  "first_name" TEXT NOT NULL,
  "last_name" TEXT NOT NULL,
  "full_name" TEXT GENERATED ALWAYS AS (first_name || ' ' || last_name)
)

-- Stored
CREATE TABLE products (
  "price" REAL NOT NULL,
  "quantity" INTEGER NOT NULL,
  "total_value" REAL GENERATED ALWAYS AS (price * quantity) STORED
)
```

### Basic Queries

#### Insert

```elixir
# Using changesets (recommended)
{:ok, user} =
  %MyApp.User{}
  |> MyApp.User.changeset(%{
    name: "Alice",
    email: "alice@example.com",
    age: 30
  })
  |> MyApp.Repo.insert()

# Direct insert
{:ok, user} = MyApp.Repo.insert(%MyApp.User{
  name: "Bob",
  email: "bob@example.com"
})
```

#### Read

```elixir
# Get by ID
user = MyApp.Repo.get(MyApp.User, 1)

# Get by field
user = MyApp.Repo.get_by(MyApp.User, email: "alice@example.com")

# Get all
users = MyApp.Repo.all(MyApp.User)

# Get one or nil
user = MyApp.Repo.one(MyApp.User)
```

#### Update

```elixir
user = MyApp.Repo.get(MyApp.User, 1)

{:ok, updated_user} =
  user
  |> MyApp.User.changeset(%{age: 31})
  |> MyApp.Repo.update()

# Or using Ecto.Changeset.change/2
{:ok, updated} =
  user
  |> Ecto.Changeset.change(age: 32)
  |> MyApp.Repo.update()
```

#### Delete

```elixir
user = MyApp.Repo.get(MyApp.User, 1)
{:ok, deleted_user} = MyApp.Repo.delete(user)
```

### Advanced Queries

```elixir
import Ecto.Query

# Filter and order
adults =
  MyApp.User
  |> where([u], u.age >= 18)
  |> order_by([u], desc: u.inserted_at)
  |> MyApp.Repo.all()

# Select specific fields
names =
  MyApp.User
  |> select([u], u.name)
  |> MyApp.Repo.all()

# Count
count =
  MyApp.User
  |> where([u], u.active == true)
  |> MyApp.Repo.aggregate(:count)

# Average
avg_age =
  MyApp.User
  |> MyApp.Repo.aggregate(:avg, :age)

# With LIKE
results =
  MyApp.User
  |> where([u], like(u.name, ^"%Alice%"))
  |> MyApp.Repo.all()

# Limit and offset
page_1 =
  MyApp.User
  |> limit(10)
  |> offset(0)
  |> MyApp.Repo.all()

# Join with posts
users_with_posts =
  MyApp.User
  |> join(:inner, [u], p in assoc(u, :posts))
  |> where([u, p], p.published == true)
  |> select([u, p], {u.name, p.title})
  |> MyApp.Repo.all()

# Group by
post_counts =
  MyApp.Post
  |> group_by([p], p.user_id)
  |> select([p], {p.user_id, count(p.id)})
  |> MyApp.Repo.all()
```

### Associations and Preloading

```elixir
# Preload posts for a user
user =
  MyApp.User
  |> MyApp.Repo.get(1)
  |> MyApp.Repo.preload(:posts)

IO.inspect(user.posts)  # List of posts

# Preload with query
user =
  MyApp.User
  |> MyApp.Repo.get(1)
  |> MyApp.Repo.preload(posts: from(p in MyApp.Post, where: p.published == true))

# Build association
user = MyApp.Repo.get(MyApp.User, 1)

{:ok, post} =
  user
  |> Ecto.build_assoc(:posts)
  |> MyApp.Post.changeset(%{title: "New Post", body: "Content"})
  |> MyApp.Repo.insert()

# Multiple associations
user =
  MyApp.User
  |> MyApp.Repo.get(1)
  |> MyApp.Repo.preload([:posts, :comments])
```

### Transactions

```elixir
# Successful transaction
{:ok, %{user: user, post: post}} =
  MyApp.Repo.transaction(fn ->
    {:ok, user} =
      %MyApp.User{}
      |> MyApp.User.changeset(%{name: "Alice", email: "alice@example.com"})
      |> MyApp.Repo.insert()

    {:ok, post} =
      user
      |> Ecto.build_assoc(:posts)
      |> MyApp.Post.changeset(%{title: "First Post", body: "Hello!"})
      |> MyApp.Repo.insert()

    %{user: user, post: post}
  end)

# Transaction with rollback
MyApp.Repo.transaction(fn ->
  user = MyApp.Repo.insert!(%MyApp.User{name: "Bob", email: "bob@example.com"})

  if some_condition do
    MyApp.Repo.rollback(:custom_reason)
  end

  user
end)
```

### Batch Operations

```elixir
# Insert many records at once
users_data = [
  %{name: "User 1", email: "user1@example.com", inserted_at: NaiveDateTime.utc_now(), updated_at: NaiveDateTime.utc_now()},
  %{name: "User 2", email: "user2@example.com", inserted_at: NaiveDateTime.utc_now(), updated_at: NaiveDateTime.utc_now()},
  %{name: "User 3", email: "user3@example.com", inserted_at: NaiveDateTime.utc_now(), updated_at: NaiveDateTime.utc_now()}
]

{3, nil} = MyApp.Repo.insert_all(MyApp.User, users_data)

# Update many records
{count, _} =
  MyApp.User
  |> where([u], u.age < 18)
  |> MyApp.Repo.update_all(set: [active: false])

# Increment view count
{1, _} =
  MyApp.Post
  |> where([p], p.id == ^post_id)
  |> MyApp.Repo.update_all(inc: [view_count: 1])

# Delete many records
{count, _} =
  MyApp.User
  |> where([u], u.active == false)
  |> MyApp.Repo.delete_all()
```

### Streaming Large Datasets

**Note:** Ecto `Repo.stream()` is not yet supported. For streaming large result sets, use the DBConnection cursor interface (see [Cursor Streaming](#cursor-streaming) section above).

### Phoenix Integration

EctoLibSql works seamlessly with Phoenix:

#### 1. Add to a new Phoenix project

```bash
mix phx.new my_app --database libsqlex
```

#### 2. Or update existing Phoenix project

```elixir
# config/dev.exs
config :my_app, MyApp.Repo,
  adapter: Ecto.Adapters.LibSql,
  database: "my_app_dev.db",
  pool_size: 5,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

# config/prod.exs (Remote Replica Mode)
config :my_app, MyApp.Repo,
  adapter: Ecto.Adapters.LibSql,
  database: "prod_replica.db",
  uri: System.get_env("TURSO_URL"),
  auth_token: System.get_env("TURSO_AUTH_TOKEN"),
  sync: true,
  pool_size: 10
```

#### 3. Use in Phoenix contexts

```elixir
defmodule MyApp.Accounts do
  import Ecto.Query
  alias MyApp.{Repo, User}

  def list_users do
    Repo.all(User)
  end

  def get_user!(id), do: Repo.get!(User, id)

  def create_user(attrs \\ %{}) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  def update_user(%User{} = user, attrs) do
    user
    |> User.changeset(attrs)
    |> Repo.update()
  end

  def delete_user(%User{} = user) do
    Repo.delete(user)
  end
end
```

#### 4. Use in Phoenix controllers

```elixir
defmodule MyAppWeb.UserController do
  use MyAppWeb, :controller
  alias MyApp.Accounts

  def index(conn, _params) do
    users = Accounts.list_users()
    render(conn, :index, users: users)
  end

  def show(conn, %{"id" => id}) do
    user = Accounts.get_user!(id)
    render(conn, :show, user: user)
  end

  def create(conn, %{"user" => user_params}) do
    case Accounts.create_user(user_params) do
      {:ok, user} ->
        conn
        |> put_status(:created)
        |> render(:show, user: user)

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, changeset: changeset)
    end
  end
end
```

### Production Deployment with Turso

For production apps, use Turso's remote replica mode for the best performance:

```elixir
# config/runtime.exs
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

**Setup Turso:**

```bash
# Install Turso CLI
curl -sSfL https://get.tur.so/install.sh | bash

# Create database
turso db create my-app-prod

# Get connection details
turso db show my-app-prod --url
turso db tokens create my-app-prod

# Set environment variables
export TURSO_URL="libsql://my-app-prod-....turso.io"
export TURSO_AUTH_TOKEN="eyJ..."
```

**Benefits:**
- 🚀 **Microsecond read latency** (local SQLite file)
- ☁️ **Automatic cloud sync** to Turso
- 🌍 **Global distribution** via Turso edge
- 💪 **Offline capability** - works without network

### Limitations and Known Issues

#### freeze_replica/1 - NOT SUPPORTED

The `EctoLibSql.Native.freeze_replica/1` function is **not implemented**. This function was intended to convert a remote replica into a standalone local database (useful for disaster recovery or field deployments).

**Status**: ⛔ Not supported - returns `{:error, :unsupported}`

**Why**: Converting a replica to primary requires taking ownership of the database connection, which is held in a shared `Arc<Mutex<>>` within the connection pool. This requires deep refactoring of the connection pool architecture that hasn't been completed.

**Workarounds** for disaster recovery scenarios:

1. **Backup and restore**: Copy the replica database file and use it independently
   ```bash
   cp replica.db standalone.db
   # Configure your app to use standalone.db directly
   ```

2. **Data replication**: Replicate all data to a new local database
   ```elixir
   # In your application, read from replica and write to new local database
   source_state = EctoLibSql.connect(database: "replica.db")
   target_state = EctoLibSql.connect(database: "new_primary.db")
   
   {:ok, _, result, _} = EctoLibSql.handle_execute(
     "SELECT * FROM table_name", [], [], source_state
   )
   # ... transfer rows to target_state
   ```

3. **Application-level failover**: Keep the replica and manage failover at the application level
   ```elixir
   defmodule MyApp.DatabaseFailover do
     def connect_with_fallback(replica_opts, backup_opts) do
       case EctoLibSql.connect(replica_opts) do
         {:ok, state} -> {:ok, state}
         {:error, _} -> EctoLibSql.connect(backup_opts)  # Fall back to backup DB
       end
     end
   end
   ```

### Type Mappings

Ecto types map to SQLite types as follows:

| Ecto Type | SQLite Type | Notes |
|-----------|-------------|-------|
| `:id` / `:integer` | `INTEGER` | ✅ Works perfectly |
| `:string` | `TEXT` | ✅ Works perfectly |
| `:binary_id` / `:uuid` | `TEXT` | ✅ Stored as text, works with Ecto.UUID |
| `:binary` | `BLOB` | ✅ Works perfectly |
| `:boolean` | `INTEGER` | ✅ 0 = false, 1 = true |
| `:float` | `REAL` | ✅ Works perfectly |
| `:decimal` | `DECIMAL` | ✅ Works perfectly |
| `:text` | `TEXT` | ✅ Works perfectly |
| `:date` | `DATE` | ✅ Stored as ISO8601 |
| `:time` | `TIME` | ✅ Stored as ISO8601 |
| `:naive_datetime` | `DATETIME` | ✅ Stored as ISO8601 |
| `:utc_datetime` | `DATETIME` | ✅ Stored as ISO8601 |
| `:map` / `:json` | `TEXT` | ✅ Stored as JSON |
| `{:array, _}` | ❌ Not supported | Use JSON or separate tables |

### Ecto Migration Notes

Most Ecto migrations work perfectly. LibSQL provides extensions beyond standard SQLite:

```elixir
# ✅ FULLY SUPPORTED
create table(:users)                                    # CREATE TABLE
create table(:sessions, options: [random_rowid: true]) # RANDOM ROWID (libSQL extension)
alter table(:users) do: add :field, :type              # ADD COLUMN
alter table(:users) do: modify :field, :new_type       # ALTER COLUMN (libSQL extension)
alter table(:users) do: remove :field                  # DROP COLUMN (libSQL/SQLite 3.35.0+)
drop table(:users)                                      # DROP TABLE
create index(:users, [:email])                         # CREATE INDEX
rename table(:old), to: table(:new)                    # RENAME TABLE
rename table(:users), :old_field, to: :new_field       # RENAME COLUMN

# ⚠️ LIBSQL EXTENSIONS (not in standard SQLite)
alter table(:users) do: modify :age, :string           # ALTER COLUMN - libSQL only
create table(:sessions, options: [random_rowid: true]) # RANDOM ROWID - libSQL only

# ✅ SQLite 3.31+ / LIBSQL
add :full_name, :string, generated: "first || ' ' || last"    # VIRTUAL computed column
add :total, :float, generated: "price * qty", stored: true    # STORED computed column
```

**Important Notes:**

1. **ALTER COLUMN** is a libSQL extension (not available in standard SQLite)
   - Supported operations: type changes, NOT NULL, DEFAULT, CHECK, REFERENCES
   - Changes only apply to new/updated rows; existing data is not revalidated

2. **DROP COLUMN** requires SQLite 3.35.0+ or libSQL
   - Cannot drop PRIMARY KEY columns, UNIQUE columns, or referenced columns

3. **RANDOM ROWID** is a libSQL extension for security/privacy
   - Prevents ID enumeration attacks
   - Mutually exclusive with WITHOUT ROWID and AUTOINCREMENT

4. **Generated Columns** are available in SQLite 3.31+ and libSQL
   - Use `generated: "expression"` option with optional `stored: true`
   - Cannot have DEFAULT values or be PRIMARY KEYs
   - STORED columns are persisted; VIRTUAL columns are computed on read

**Standard SQLite Workaround (if not using libSQL's ALTER COLUMN):**

If you need to modify columns on standard SQLite (without libSQL's extensions), recreate the table:

```elixir
defmodule MyApp.Repo.Migrations.ChangeUserAge do
  use Ecto.Migration

  def up do
    create table(:users_new) do
      add :id, :integer, primary_key: true
      add :name, :string
      add :email, :string
      add :age, :string  # Changed from :integer
      timestamps()
    end

    execute "INSERT INTO users_new (id, name, email, age, inserted_at, updated_at) SELECT id, name, email, CAST(age AS TEXT), inserted_at, updated_at FROM users"
    drop table(:users)
    rename table(:users_new), to: table(:users)

    # Recreate indexes
    create unique_index(:users, [:email])
  end
end
```

---

## API Reference

### Connection Functions

#### `EctoLibSql.connect/1`

Opens a database connection.

**Parameters:**
- `opts` (keyword list): Connection options

**Options:**
- `:database` - Local database file path
- `:uri` - Remote database URI (libsql://, https://, or wss://)
- `:auth_token` - Authentication token for remote connections
- `:sync` - Enable auto-sync for replicas (true/false)
- `:encryption_key` - Encryption key (min 32 chars)

**Returns:** `{:ok, state}` or `{:error, reason}`

#### `EctoLibSql.disconnect/2`

Closes a database connection.

**Parameters:**
- `opts` (keyword list): Options (currently unused)
- `state` (EctoLibSql.State): Connection state

**Returns:** `:ok`

#### `EctoLibSql.ping/1`

Checks if connection is alive.

**Parameters:**
- `state` (EctoLibSql.State): Connection state

**Returns:** `{:ok, state}` or `{:disconnect, reason, state}`

### Query Functions

#### `EctoLibSql.handle_execute/4`

Executes a SQL query.

**Parameters:**
- `query` (String.t() | EctoLibSql.Query): SQL query
- `params` (list): Query parameters
- `opts` (keyword list): Options
- `state` (EctoLibSql.State): Connection state

**Returns:** `{:ok, query, result, state}` or `{:error, query, reason, state}`

### Transaction Functions

#### `EctoLibSql.handle_begin/2`

Begins a transaction.

**Parameters:**
- `opts` (keyword list): Options
- `state` (EctoLibSql.State): Connection state

**Returns:** `{:ok, :begin, state}` or `{:error, reason, state}`

#### `EctoLibSql.handle_commit/2`

Commits a transaction.

**Parameters:**
- `opts` (keyword list): Options
- `state` (EctoLibSql.State): Connection state

**Returns:** `{:ok, result, state}` or `{:error, reason, state}`

#### `EctoLibSql.handle_rollback/2`

Rolls back a transaction.

**Parameters:**
- `opts` (keyword list): Options
- `state` (EctoLibSql.State): Connection state

**Returns:** `{:ok, result, state}` or `{:error, reason, state}`

#### `EctoLibSql.Native.begin/2`

Begins a transaction with specific behaviour.

**Parameters:**
- `state` (EctoLibSql.State): Connection state
- `opts` (keyword list): Options
  - `:behaviour` - `:deferred`, `:immediate`, `:exclusive`, or `:read_only`

**Returns:** `{:ok, state}` or `{:error, reason}`

### Prepared Statement Functions

#### `EctoLibSql.Native.prepare/2`

Prepares a SQL statement.

**Parameters:**
- `state` (EctoLibSql.State): Connection state
- `sql` (String.t()): SQL query

**Returns:** `{:ok, stmt_id}` or `{:error, reason}`

#### `EctoLibSql.Native.query_stmt/3`

Executes a prepared SELECT statement.

**Parameters:**
- `state` (EctoLibSql.State): Connection state
- `stmt_id` (String.t()): Statement ID
- `args` (list): Query parameters

**Returns:** `{:ok, result}` or `{:error, reason}`

#### `EctoLibSql.Native.execute_stmt/4`

Executes a prepared non-SELECT statement.

**Parameters:**
- `state` (EctoLibSql.State): Connection state
- `stmt_id` (String.t()): Statement ID
- `sql` (String.t()): Original SQL (for sync detection)
- `args` (list): Query parameters

**Returns:** `{:ok, num_rows}` or `{:error, reason}`

#### `EctoLibSql.Native.close_stmt/1`

Closes a prepared statement.

**Parameters:**
- `stmt_id` (String.t()): Statement ID

**Returns:** `:ok` or `{:error, reason}`

### Batch Functions

#### `EctoLibSql.Native.batch/2`

Executes multiple statements independently.

**Parameters:**
- `state` (EctoLibSql.State): Connection state
- `statements` (list): List of `{sql, params}` tuples

**Returns:** `{:ok, results}` or `{:error, reason}`

#### `EctoLibSql.Native.batch_transactional/2`

Executes multiple statements in a transaction.

**Parameters:**
- `state` (EctoLibSql.State): Connection state
- `statements` (list): List of `{sql, params}` tuples

**Returns:** `{:ok, results}` or `{:error, reason}`

### Cursor Functions

#### `EctoLibSql.handle_declare/4`

Declares a cursor for streaming results.

**Parameters:**
- `query` (EctoLibSql.Query): SQL query
- `params` (list): Query parameters
- `opts` (keyword list): Options
- `state` (EctoLibSql.State): Connection state

**Returns:** `{:ok, query, cursor, state}` or `{:error, reason, state}`

#### `EctoLibSql.handle_fetch/4`

Fetches rows from a cursor.

**Parameters:**
- `query` (EctoLibSql.Query): SQL query
- `cursor`: Cursor reference
- `opts` (keyword list): Options
  - `:max_rows` - Maximum rows per fetch (default 500)
- `state` (EctoLibSql.State): Connection state

**Returns:** `{:cont, result, state}`, `{:deallocated, result, state}`, or `{:error, reason, state}`

### Metadata Functions

#### `EctoLibSql.Native.get_last_insert_rowid/1`

Gets the rowid of the last inserted row.

**Parameters:**
- `state` (EctoLibSql.State): Connection state

**Returns:** Integer rowid

#### `EctoLibSql.Native.get_changes/1`

Gets the number of rows changed by the last statement.

**Parameters:**
- `state` (EctoLibSql.State): Connection state

**Returns:** Integer count

#### `EctoLibSql.Native.get_total_changes/1`

Gets the total number of rows changed since connection opened.

**Parameters:**
- `state` (EctoLibSql.State): Connection state

**Returns:** Integer count

#### `EctoLibSql.Native.get_is_autocommit/1`

Checks if connection is in autocommit mode.

**Parameters:**
- `state` (EctoLibSql.State): Connection state

**Returns:** Boolean

### Vector Functions

#### `EctoLibSql.Native.vector/1`

Creates a vector string from a list of numbers.

**Parameters:**
- `values` (list): List of numbers

**Returns:** String vector representation

#### `EctoLibSql.Native.vector_type/2`

Creates a vector column type definition.

**Parameters:**
- `dimensions` (integer): Number of dimensions
- `type` (atom): `:f32` or `:f64` (default `:f32`)

**Returns:** String column type (e.g., "F32_BLOB(3)")

#### `EctoLibSql.Native.vector_distance_cos/2`

Generates SQL for cosine distance calculation.

**Parameters:**
- `column` (String.t()): Column name
- `vector` (list | String.t()): Query vector

**Returns:** String SQL expression

### JSON Helper Functions (EctoLibSql.JSON)

The `EctoLibSql.JSON` module provides helpers for working with JSON and JSONB data in libSQL 3.45.1+.

#### `EctoLibSql.JSON.extract/3`

Extract a value from JSON at the specified path.

**Parameters:**
- `state` (EctoLibSql.State): Connection state
- `json` (String.t() | binary): JSON text or JSONB binary data
- `path` (String.t()): JSON path expression (e.g., "$.key" or "$[0]")

**Returns:** `{:ok, value}` or `{:error, reason}`

#### `EctoLibSql.JSON.type/2` and `EctoLibSql.JSON.type/3`

Get the type of a value in JSON at the specified path.

**Parameters:**
- `state` (EctoLibSql.State): Connection state
- `json` (String.t() | binary): JSON text or JSONB binary data
- `path` (String.t(), optional, default "$"): JSON path expression

**Returns:** `{:ok, type}` where type is one of: null, true, false, integer, real, text, array, object

#### `EctoLibSql.JSON.is_valid/2`

Check if a string is valid JSON.

**Parameters:**
- `state` (EctoLibSql.State): Connection state
- `json` (String.t()): String to validate as JSON

**Returns:** `{:ok, boolean}` or `{:error, reason}`

#### `EctoLibSql.JSON.array/2`

Create a JSON array from a list of values.

**Parameters:**
- `state` (EctoLibSql.State): Connection state
- `values` (list): List of values to include in the array

**Returns:** `{:ok, json_array}` - JSON text representation of the array

#### `EctoLibSql.JSON.object/2`

Create a JSON object from a list of key-value pairs.

**Parameters:**
- `state` (EctoLibSql.State): Connection state
- `pairs` (list): List of alternating [key1, value1, key2, value2, ...]

**Returns:** `{:ok, json_object}` - JSON text representation of the object

#### `EctoLibSql.JSON.each/2` and `EctoLibSql.JSON.each/3`

Iterate over elements of a JSON array or object members.

**Parameters:**
- `state` (EctoLibSql.State): Connection state
- `json` (String.t() | binary): JSON text or JSONB binary data
- `path` (String.t(), optional, default "$"): JSON path expression

**Returns:** `{:ok, [{key, value, type}]}` - List of members with metadata

#### `EctoLibSql.JSON.tree/2` and `EctoLibSql.JSON.tree/3`

Recursively iterate over all values in a JSON structure.

**Parameters:**
- `state` (EctoLibSql.State): Connection state
- `json` (String.t() | binary): JSON text or JSONB binary data
- `path` (String.t(), optional, default "$"): JSON path expression

**Returns:** `{:ok, [{full_key, atom, type}]}` - List of all values with paths

#### `EctoLibSql.JSON.convert/2` and `EctoLibSql.JSON.convert/3`

Convert text JSON to canonical form, optionally returning JSONB binary format.

**Parameters:**
- `state` (EctoLibSql.State): Connection state
- `json` (String.t()): JSON text string
- `format` (`:json | :jsonb`, optional, default `:json`): Output format

**Returns:** `{:ok, json}` as text or `{:ok, jsonb}` as binary, or `{:error, reason}`

#### `EctoLibSql.JSON.arrow_fragment/2` and `EctoLibSql.JSON.arrow_fragment/3`

Helper to create SQL fragments for Ecto queries using JSON operators.

**Parameters:**
- `json_column` (String.t()): Column name or fragment
- `path` (String.t() | integer): JSON path (string key or array index)
- `operator` (`:arrow | :double_arrow`, optional, default `:arrow`): Operator type

**Returns:** String for use in `Ecto.Query.fragment/1`

### Sync Functions

#### `EctoLibSql.Native.sync/1`

Manually synchronises a remote replica.

**Parameters:**
- `state` (EctoLibSql.State): Connection state

**Returns:** `{:ok, message}` or `{:error, reason}`

#### `EctoLibSql.Native.get_frame_number_for_replica/1` (v0.7.0+)

Get current replication frame number.

**Parameters:**
- `state` (EctoLibSql.State): Connection state

**Returns:** `{:ok, frame_number}` or `{:error, reason}`

#### `EctoLibSql.Native.sync_until_frame/2` (v0.7.0+)

Synchronise replica until specified frame number.

**Parameters:**
- `state` (EctoLibSql.State): Connection state
- `frame_number` (integer): Target frame number

**Returns:** `{:ok, state}` or `{:error, reason}`

#### `EctoLibSql.Native.flush_and_get_frame/1` (v0.7.0+)

Flush pending writes and get frame number.

**Parameters:**
- `state` (EctoLibSql.State): Connection state

**Returns:** `{:ok, frame_number}` or `{:error, reason}`

#### `EctoLibSql.Native.max_write_replication_index/1` (v0.7.0+)

Get the highest replication frame from write operations (for read-your-writes consistency).

**Parameters:**
- `state` (EctoLibSql.State): Connection state

**Returns:** `{:ok, frame_number}` or `{:error, reason}`

### Connection Management Functions

#### `EctoLibSql.Native.busy_timeout/2` (v0.7.0+)

Configure database busy timeout.

**Parameters:**
- `state` (EctoLibSql.State): Connection state
- `timeout_ms` (integer): Timeout in milliseconds

**Returns:** `{:ok, state}` or `{:error, reason}`

#### `EctoLibSql.Native.reset/1` (v0.7.0+)

Reset connection state without closing.

**Parameters:**
- `state` (EctoLibSql.State): Connection state

**Returns:** `{:ok, state}` or `{:error, reason}`

#### `EctoLibSql.Native.interrupt/1` (v0.7.0+)

Interrupt a long-running query.

**Parameters:**
- `state` (EctoLibSql.State): Connection state

**Returns:** `:ok`

### Savepoint Functions

#### `EctoLibSql.Native.create_savepoint/2` (v0.7.0+)

Create a named savepoint within a transaction.

**Parameters:**
- `state` (EctoLibSql.State): Connection state
- `name` (String.t()): Savepoint name (alphanumeric only)

**Returns:** `{:ok, state}` or `{:error, reason}`

#### `EctoLibSql.Native.release_savepoint_by_name/2` (v0.7.0+)

Release (commit) a savepoint.

**Parameters:**
- `state` (EctoLibSql.State): Connection state
- `name` (String.t()): Savepoint name

**Returns:** `{:ok, state}` or `{:error, reason}`

#### `EctoLibSql.Native.rollback_to_savepoint_by_name/2` (v0.7.0+)

Rollback to a savepoint (keeps transaction active).

**Parameters:**
- `state` (EctoLibSql.State): Connection state
- `name` (String.t()): Savepoint name

**Returns:** `{:ok, state}` or `{:error, reason}`

### Statement Introspection Functions

#### `EctoLibSql.Native.stmt_parameter_count/2` (v0.7.0+)

Get number of parameters in prepared statement.

**Parameters:**
- `state` (EctoLibSql.State): Connection state
- `stmt_id` (String.t()): Statement ID

**Returns:** `{:ok, count}` or `{:error, reason}`

#### `EctoLibSql.Native.stmt_column_count/2` (v0.7.0+)

Get number of columns in prepared statement result.

**Parameters:**
- `state` (EctoLibSql.State): Connection state
- `stmt_id` (String.t()): Statement ID

**Returns:** `{:ok, count}` or `{:error, reason}`

#### `EctoLibSql.Native.stmt_column_name/3` (v0.7.0+)

Get column name by index from prepared statement.

**Parameters:**
- `state` (EctoLibSql.State): Connection state
- `stmt_id` (String.t()): Statement ID
- `index` (integer): Column index (0-based)

**Returns:** `{:ok, name}` or `{:error, reason}`

#### `EctoLibSql.Native.stmt_parameter_name/3` (v0.8.3+)

Get parameter name by index from prepared statement.

**Parameters:**
- `state` (EctoLibSql.State): Connection state
- `stmt_id` (String.t()): Statement ID
- `index` (integer): Parameter index (1-based)

**Returns:** `{:ok, name}` for named parameters (`:name`, `@name`, `$name`), `{:ok, nil}` for positional `?` placeholders, or `{:error, reason}`

#### `EctoLibSql.Native.reset_stmt/2` (v0.8.3+)

Reset a prepared statement to its initial state for reuse.

**Parameters:**
- `state` (EctoLibSql.State): Connection state
- `stmt_id` (String.t()): Statement ID

**Returns:** `:ok` or `{:error, reason}`

#### `EctoLibSql.Native.get_stmt_columns/2` (v0.8.3+)

Get column metadata for a prepared statement.

**Parameters:**
- `state` (EctoLibSql.State): Connection state
- `stmt_id` (String.t()): Statement ID

**Returns:** `{:ok, [{name, origin_name, decl_type}]}` or `{:error, reason}`

### Batch SQL Functions

#### `EctoLibSql.Native.execute_batch_sql/2` (v0.7.0+)

Execute multiple SQL statements (non-transactional).

**Parameters:**
- `state` (EctoLibSql.State): Connection state
- `sql` (String.t()): Multiple SQL statements separated by semicolons

**Returns:** `{:ok, state}` or `{:error, reason}`

#### `EctoLibSql.Native.execute_transactional_batch_sql/2` (v0.7.0+)

Execute multiple SQL statements atomically in a transaction.

**Parameters:**
- `state` (EctoLibSql.State): Connection state
- `sql` (String.t()): Multiple SQL statements separated by semicolons

**Returns:** `{:ok, state}` or `{:error, reason}`

### Extension Loading Functions (v0.8.3+)

#### `EctoLibSql.Native.enable_extensions/2`

Enable or disable SQLite extension loading for a connection.

**Parameters:**
- `state` (EctoLibSql.State): Connection state
- `enabled` (boolean): `true` to enable, `false` to disable

**Returns:** `:ok` or `{:error, reason}`

**Security Warning:** Only enable extension loading if you trust the extensions being loaded.

#### `EctoLibSql.Native.load_ext/3`

Load a SQLite extension from a dynamic library file.

**Parameters:**
- `state` (EctoLibSql.State): Connection state
- `path` (String.t()): Path to extension (.so, .dylib, or .dll)
- `entry_point` (String.t() | nil): Optional custom entry point function

**Returns:** `:ok` or `{:error, reason}`

**Note:** Extension loading must be enabled first via `enable_extensions/2`.

---

## Real-World Examples

### Building a Blog API

```elixir
defmodule MyApp.Blog do
  def setup(state) do
    # Create tables
    {:ok, _, _, state} = EctoLibSql.handle_execute(
      """
      CREATE TABLE IF NOT EXISTS posts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        content TEXT NOT NULL,
        author_id INTEGER NOT NULL,
        published_at INTEGER,
        created_at INTEGER NOT NULL
      )
      """,
      [],
      [],
      state
    )

    {:ok, _, _, state} = EctoLibSql.handle_execute(
      """
      CREATE INDEX IF NOT EXISTS idx_posts_author ON posts(author_id)
      """,
      [],
      [],
      state
    )

    {:ok, _, _, state} = EctoLibSql.handle_execute(
      """
      CREATE INDEX IF NOT EXISTS idx_posts_published ON posts(published_at)
      """,
      [],
      [],
      state
    )

    {:ok, state}
  end

  def create_post(state, title, content, author_id) do
    {:ok, _, _, state} = EctoLibSql.handle_execute(
      """
      INSERT INTO posts (title, content, author_id, created_at)
      VALUES (?, ?, ?, ?)
      """,
      [title, content, author_id, System.system_time(:second)],
      [],
      state
    )

    post_id = EctoLibSql.Native.get_last_insert_rowid(state)
    {:ok, post_id, state}
  end

  def publish_post(state, post_id) do
    EctoLibSql.handle_execute(
      "UPDATE posts SET published_at = ? WHERE id = ?",
      [System.system_time(:second), post_id],
      [],
      state
    )
  end

  def list_published_posts(state, limit \\ 10) do
    {:ok, _, result, state} = EctoLibSql.handle_execute(
      """
      SELECT id, title, author_id, published_at
      FROM posts
      WHERE published_at IS NOT NULL
      ORDER BY published_at DESC
      LIMIT ?
      """,
      [limit],
      [],
      state
    )

    posts = Enum.map(result.rows, fn [id, title, author_id, published_at] ->
      %{id: id, title: title, author_id: author_id, published_at: published_at}
    end)

    {:ok, posts, state}
  end

  def get_post(state, post_id) do
    {:ok, _, result, state} = EctoLibSql.handle_execute(
      "SELECT id, title, content, author_id, published_at FROM posts WHERE id = ?",
      [post_id],
      [],
      state
    )

    case result.rows do
      [[id, title, content, author_id, published_at]] ->
        {:ok,
         %{
           id: id,
           title: title,
           content: content,
           author_id: author_id,
           published_at: published_at
         }, state}

      [] ->
        {:error, :not_found, state}
    end
  end
end
```

### E-commerce Order Processing

```elixir
defmodule MyApp.Orders do
  def create_order(state, user_id, items) do
    # Start transaction
    {:ok, :begin, state} = EctoLibSql.handle_begin([], state)

    # Create order
    {:ok, _, _, state} = EctoLibSql.handle_execute(
      """
      INSERT INTO orders (user_id, status, total, created_at)
      VALUES (?, 'pending', 0, ?)
      """,
      [user_id, System.system_time(:second)],
      [],
      state
    )

    order_id = EctoLibSql.Native.get_last_insert_rowid(state)

    # Add order items and calculate total
    {total, state} =
      Enum.reduce(items, {0, state}, fn %{product_id: pid, quantity: qty}, {acc, st} ->
        # Get product price
        {:ok, _, result, st} = EctoLibSql.handle_execute(
          "SELECT price FROM products WHERE id = ?",
          [pid],
          [],
          st
        )

        [[price]] = result.rows
        subtotal = price * qty

        # Insert order item
        {:ok, _, _, st} = EctoLibSql.handle_execute(
          """
          INSERT INTO order_items (order_id, product_id, quantity, price, subtotal)
          VALUES (?, ?, ?, ?, ?)
          """,
          [order_id, pid, qty, price, subtotal],
          [],
          st
        )

        # Update product inventory
        {:ok, _, _, st} = EctoLibSql.handle_execute(
          "UPDATE products SET stock = stock - ? WHERE id = ? AND stock >= ?",
          [qty, pid, qty],
          [],
          st
        )

        {acc + subtotal, st}
      end)

    # Update order total
    {:ok, _, _, state} = EctoLibSql.handle_execute(
      "UPDATE orders SET total = ? WHERE id = ?",
      [total, order_id],
      [],
      state
    )

    # Commit transaction
    {:ok, _, state} = EctoLibSql.handle_commit([], state)

    {:ok, order_id, state}
  rescue
    error ->
      EctoLibSql.handle_rollback([], state)
      {:error, error}
  end
end
```

### Analytics Dashboard

```elixir
defmodule MyApp.Analytics do
  def get_user_stats(state, user_id) do
    # Use batch to fetch multiple metrics at once
    statements = [
      # Total posts
      {"SELECT COUNT(*) FROM posts WHERE author_id = ?", [user_id]},

      # Total views
      {"SELECT SUM(view_count) FROM posts WHERE author_id = ?", [user_id]},

      # Average engagement
      {"""
       SELECT AVG(like_count + comment_count) as avg_engagement
       FROM posts
       WHERE author_id = ?
       """, [user_id]},

      # Recent activity
      {"""
       SELECT COUNT(*)
       FROM posts
       WHERE author_id = ?
       AND created_at > ?
       """, [user_id, days_ago(7)]}
    ]

    {:ok, results} = EctoLibSql.Native.batch(state, statements)

    [total_posts, total_views, avg_engagement, recent_posts] = results

    %{
      total_posts: hd(hd(total_posts.rows)),
      total_views: hd(hd(total_views.rows)) || 0,
      avg_engagement: hd(hd(avg_engagement.rows)) || 0.0,
      posts_last_7_days: hd(hd(recent_posts.rows))
    }
  end

  defp days_ago(days) do
    System.system_time(:second) - days * 24 * 60 * 60
  end
end
```

### Semantic Search Engine

```elixir
defmodule MyApp.SemanticSearch do
  @dimensions 384  # all-MiniLM-L6-v2 model

  def setup(state) do
    vector_col = EctoLibSql.Native.vector_type(@dimensions, :f32)

    {:ok, _, _, state} = EctoLibSql.handle_execute(
      """
      CREATE TABLE IF NOT EXISTS documents (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        content TEXT NOT NULL,
        category TEXT,
        embedding #{vector_col},
        indexed_at INTEGER NOT NULL
      )
      """,
      [],
      [],
      state
    )

    {:ok, state}
  end

  def index_document(state, title, content, category) do
    # Generate embedding
    embedding = MyApp.Embeddings.encode(content)
    vec = EctoLibSql.Native.vector(embedding)

    {:ok, _, _, state} = EctoLibSql.handle_execute(
      """
      INSERT INTO documents (title, content, category, embedding, indexed_at)
      VALUES (?, ?, ?, vector(?), ?)
      """,
      [title, content, category, vec, System.system_time(:second)],
      [],
      state
    )

    doc_id = EctoLibSql.Native.get_last_insert_rowid(state)
    {:ok, doc_id, state}
  end

  def search(state, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    category = Keyword.get(opts, :category)

    # Generate query embedding
    query_embedding = MyApp.Embeddings.encode(query)
    distance_sql = EctoLibSql.Native.vector_distance_cos("embedding", query_embedding)

    # Build SQL with optional category filter
    {sql, params} = if category do
      {"""
       SELECT id, title, content, category, #{distance_sql} as score
       FROM documents
       WHERE category = ?
       ORDER BY score
       LIMIT ?
       """, [category, limit]}
    else
      {"""
       SELECT id, title, content, category, #{distance_sql} as score
       FROM documents
       ORDER BY score
       LIMIT ?
       """, [limit]}
    end

    {:ok, _, result, state} = EctoLibSql.handle_execute(sql, params, [], state)

    results = Enum.map(result.rows, fn [id, title, content, cat, score] ->
      %{
        id: id,
        title: title,
        content: content,
        category: cat,
        relevance_score: score
      }
    end)

    {:ok, results, state}
  end

  def reindex_all(conn) do
    # Use cursor for memory-efficient reindexing
    stream = DBConnection.stream(
      conn,
      %EctoLibSql.Query{statement: "SELECT id, content FROM documents"},
      []
    )

    stream
    |> Stream.flat_map(fn %{rows: rows} -> rows end)
    |> Stream.chunk_every(100)
    |> Enum.each(fn batch ->
      # Prepare batch update
      statements =
        Enum.map(batch, fn [id, content] ->
          embedding = MyApp.Embeddings.encode(content)
          vec = EctoLibSql.Native.vector(embedding)

          {"UPDATE documents SET embedding = vector(?) WHERE id = ?", [vec, id]}
        end)

      # Execute batch
      {:ok, state} = DBConnection.run(conn, fn state ->
        {:ok, _} = EctoLibSql.Native.batch_transactional(state, statements)
        {:ok, state}
      end)
    end)
  end
end
```

---

## Performance Guide

### Connection Pooling

```elixir
# config/config.exs
config :my_app, MyApp.Repo,
  pool_size: 10,
  connection: [
    database: "myapp.db"
  ]

# lib/my_app/repo.ex
defmodule MyApp.Repo do
  use DBConnection

  def start_link(opts) do
    DBConnection.start_link(EctoLibSql, opts)
  end

  def query(sql, params \\ []) do
    DBConnection.run(__MODULE__, fn conn ->
      query = %EctoLibSql.Query{statement: sql}
      DBConnection.execute(conn, query, params)
    end)
  end
end
```

### Optimising Writes

```elixir
# Use batch operations for bulk inserts
defmodule MyApp.FastImport do
  # ❌ Slow: Individual inserts
  def slow_import(state, items) do
    Enum.reduce(items, state, fn item, acc ->
      {:ok, _, _, new_state} = EctoLibSql.handle_execute(
        "INSERT INTO items (name) VALUES (?)",
        [item.name],
        [],
        acc
      )
      new_state
    end)
  end

  # ✅ Fast: Batch insert
  def fast_import(state, items) do
    statements = Enum.map(items, fn item ->
      {"INSERT INTO items (name) VALUES (?)", [item.name]}
    end)

    {:ok, _} = EctoLibSql.Native.batch_transactional(state, statements)
  end
end
```

### Query Optimisation with Prepared Statement Caching

**Prepared statements are automatically cached after preparation** - the statement is compiled once and reused with `.reset()` for binding cleanup. This provides ~10-15x performance improvement for repeated queries.

```elixir
# Use prepared statements for repeated queries
defmodule MyApp.UserLookup do
  def setup(state) do
    # Statement is prepared once and cached internally
    {:ok, stmt} = EctoLibSql.Native.prepare(
      state,
      "SELECT * FROM users WHERE email = ?"
    )

    %{state: state, lookup_stmt: stmt}
  end

  # ❌ Slow: Unprepared query (~2.5ms for 100 calls)
  def slow_lookup(state, emails) do
    Enum.each(emails, fn email ->
      {:ok, _, result, _} = EctoLibSql.handle_execute(
        "SELECT * FROM users WHERE email = ?",
        [email],
        [],
        state
      )
      IO.inspect(result)
    end)
  end

  # ✅ Fast: Reuse cached prepared statement (~330µs per call)
  def fast_lookup(context, emails) do
    Enum.each(emails, fn email ->
      {:ok, result} = EctoLibSql.Native.query_stmt(
        context.state,
        context.lookup_stmt,
        [email]
      )
      # Bindings are automatically cleared between calls via stmt.reset()
      IO.inspect(result)
    end)
  end

  def cleanup(context) do
    # Clean up when finished
    EctoLibSql.Native.close_stmt(context.lookup_stmt)
  end
end
```

**Key Insight**: Prepared statements maintain internal state across calls. The caching mechanism automatically:
- Calls `stmt.reset()` before each execution to clear parameter bindings
- Reuses the compiled statement object, avoiding re-preparation overhead
- Provides consistent performance regardless of statement complexity

#### Bulk Insert with Prepared Statements

```elixir
defmodule MyApp.BulkInsert do
  # ❌ Slow: 1000 individual inserts
  def slow_bulk_insert(state, records) do
    Enum.reduce(records, state, fn record, acc ->
      {:ok, _, _, new_state} = EctoLibSql.handle_execute(
        "INSERT INTO products (name, price) VALUES (?, ?)",
        [record.name, record.price],
        [],
        acc
      )
      new_state
    end)
  end

  # ⚡ Faster: Batch with transaction (groups into single roundtrip)
  def faster_bulk_insert(state, records) do
    statements = Enum.map(records, fn record ->
      {"INSERT INTO products (name, price) VALUES (?, ?)", [record.name, record.price]}
    end)
    EctoLibSql.Native.batch_transactional(state, statements)
  end

  # ✅ Fastest: Prepared statement + transaction (reuse + batching)
  def fastest_bulk_insert(state, records) do
    {:ok, stmt_id} = EctoLibSql.Native.prepare(
      state,
      "INSERT INTO products (name, price) VALUES (?, ?)"
    )

    {:ok, :begin, state} = EctoLibSql.handle_begin([], state)

    state = Enum.reduce(records, state, fn record, acc ->
      {:ok, _} = EctoLibSql.Native.execute_stmt(
        acc,
        stmt_id,
        "INSERT INTO products (name, price) VALUES (?, ?)",
        [record.name, record.price]
      )
      acc
    end)

    {:ok, _, state} = EctoLibSql.handle_commit([], state)
    EctoLibSql.Native.close_stmt(stmt_id)

    {:ok, state}
  end
end
```

### Replica Mode for Reads

```elixir
# Use replica mode for read-heavy workloads
opts = [
  uri: "libsql://my-db.turso.io",
  auth_token: token,
  database: "replica.db",
  sync: true  # Auto-sync on writes
]

{:ok, state} = EctoLibSql.connect(opts)

# Reads are local (microsecond latency)
{:ok, _, result, state} = EctoLibSql.handle_execute(
  "SELECT * FROM users WHERE id = ?",
  [123],
  [],
  state
)

# Writes sync to remote (millisecond latency)
{:ok, _, _, state} = EctoLibSql.handle_execute(
  "UPDATE users SET last_login = ? WHERE id = ?",
  [System.system_time(:second), 123],
  [],
  state
)
```

### Memory Management

```elixir
# Use cursors for large result sets
defmodule MyApp.LargeQuery do
  # ❌ Memory-intensive: Load all rows
  def load_all(state) do
    {:ok, _, result, _} = EctoLibSql.handle_execute(
      "SELECT * FROM huge_table",
      [],
      [],
      state
    )
    # All rows in memory!
    process_rows(result.rows)
  end

  # ✅ Memory-efficient: Stream with cursor
  def stream_all(conn) do
    DBConnection.stream(
      conn,
      %EctoLibSql.Query{statement: "SELECT * FROM huge_table"},
      [],
      max_rows: 1000
    )
    |> Stream.flat_map(fn %{rows: rows} -> rows end)
    |> Stream.each(&process_row/1)
    |> Stream.run()
  end
end
```

### Indexing Strategy

```elixir
defmodule MyApp.Schema do
  def create_optimised_schema(state) do
    statements = [
      # Main table
      {"""
       CREATE TABLE users (
         id INTEGER PRIMARY KEY AUTOINCREMENT,
         email TEXT UNIQUE NOT NULL,
         name TEXT NOT NULL,
         created_at INTEGER NOT NULL
       )
       """, []},

      # Index for frequent lookups
      {"CREATE INDEX idx_users_email ON users(email)", []},

      # Composite index for common queries
      {"CREATE INDEX idx_users_created ON users(created_at DESC)", []},

      # Covering index for specific query
      {"CREATE INDEX idx_users_name_email ON users(name, email)", []}
    ]

    EctoLibSql.Native.batch(state, statements)
  end
end
```

---

## Error Handling

### Overview

The `ecto_libsql` library uses a Rust NIF (Native Implemented Function) for its core operations. As of version 0.4.0, all error handling has been comprehensively refactored to ensure that errors are returned gracefully to Elixir rather than panicking and crashing the BEAM VM.

**Key principle:** All NIF operations that can fail now return `{:error, message}` tuples to Elixir, allowing your application's supervision tree to handle failures properly.

### Error Categories

#### 1. Connection Errors

**Invalid Connection ID:**
```elixir
# When using a stale or non-existent connection ID
result = EctoLibSql.Native.ping("invalid-connection-id")
# Returns: {:error, "Invalid connection ID"}

# Your code can handle it:
case EctoLibSql.Native.ping(conn_id) do
  {:ok, _} -> :connected
  {:error, msg} -> 
    Logger.error("Connection failed: #{msg}")
    :reconnect
end
```

**Connection Not Found:**
```elixir
# Attempting to query with closed/invalid connection
result = EctoLibSql.Native.query_args(
  closed_conn_id,
  :local,
  :disable_sync,
  "SELECT 1",
  []
)
# Returns: {:error, "Invalid connection ID"}
```

#### 2. Transaction Errors

**Transaction Not Found:**
```elixir
# Using invalid transaction ID
result = EctoLibSql.Native.execute_with_transaction(
  "invalid-trx-id",
  "INSERT INTO users VALUES (?)",
  ["Alice"]
)
# Returns: {:error, "Transaction not found"}

# Proper error handling:
case EctoLibSql.Native.execute_with_transaction(trx_id, sql, params) do
  {:ok, rows} -> {:ok, rows}
  {:error, "Transaction not found"} -> 
    # Transaction may have been rolled back or timed out
    {:error, :transaction_expired}
  {:error, msg} -> 
    {:error, msg}
end
```

#### 3. Resource Errors

**Statement Not Found:**
```elixir
# Using invalid prepared statement ID
result = EctoLibSql.Native.query_prepared(
  conn_id,
  "invalid-stmt-id",
  :local,
  :disable_sync,
  []
)
# Returns: {:error, "Statement not found"}
```

**Cursor Not Found:**
```elixir
# Using invalid cursor ID
result = EctoLibSql.Native.fetch_cursor("invalid-cursor-id", 100)
# Returns: {:error, "Cursor not found"}
```

#### 4. Mutex and Concurrency Errors

The library uses mutex locks internally to manage shared state. If a mutex becomes poisoned (due to a panic in another thread), you'll receive a descriptive error:

```elixir
# Example of mutex poisoning error (rare, but handled gracefully)
{:error, "Mutex poisoned in query_args client: poisoned lock: another task failed inside"}
```

These errors indicate an internal issue but won't crash your VM. Log them and consider restarting the connection.

### Error Handling Patterns

#### Pattern 1: Simple Case Match

```elixir
case EctoLibSql.handle_execute(sql, params, [], state) do
  {:ok, query, result, new_state} ->
    # Process result
    process_result(result)
    
  {:error, query, reason, new_state} ->
    Logger.error("Query failed: #{inspect(reason)}")
    {:error, :query_failed}
end
```

#### Pattern 2: With Clause

```elixir
with {:ok, state} <- EctoLibSql.connect(opts),
     {:ok, _, _, state} <- create_table(state),
     {:ok, _, _, state} <- insert_data(state) do
  {:ok, state}
else
  {:error, reason} ->
    Logger.error("Database setup failed: #{inspect(reason)}")
    {:error, :setup_failed}
end
```

#### Pattern 3: Supervision Tree Integration

```elixir
defmodule MyApp.DatabaseWorker do
  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    case EctoLibSql.connect(opts) do
      {:ok, state} ->
        {:ok, state}
        
      {:error, reason} ->
        Logger.error("Failed to connect: #{inspect(reason)}")
        # Supervisor will restart us
        {:stop, :connection_failed}
    end
  end

  def handle_call({:query, sql, params}, _from, state) do
    case EctoLibSql.handle_execute(sql, params, [], state) do
      {:ok, _query, result, new_state} ->
        {:reply, {:ok, result}, new_state}
        
      {:error, _query, reason, new_state} ->
        # Error is contained to this process
        # Supervisor can restart if needed
        {:reply, {:error, reason}, new_state}
    end
  end
end
```

#### Pattern 4: Retry Logic

```elixir
defmodule MyApp.Database do
  def query_with_retry(state, sql, params, retries \\ 3) do
    case EctoLibSql.handle_execute(sql, params, [], state) do
      {:ok, query, result, new_state} ->
        {:ok, result, new_state}
        
      {:error, _query, reason, new_state} when retries > 0 ->
        Logger.warn("Query failed (#{retries} retries left): #{inspect(reason)}")
        Process.sleep(100)
        query_with_retry(new_state, sql, params, retries - 1)
        
      {:error, _query, reason, new_state} ->
        Logger.error("Query failed after retries: #{inspect(reason)}")
        {:error, reason, new_state}
    end
  end
end
```

### What Changed (Technical Details)

Prior to version 0.4.0, the Rust NIF code contained 146 `unwrap()` calls that could panic and crash the entire BEAM VM. These have been completely eliminated:

**Before (would crash VM):**
```rust
let conn_map = CONNECTION_REGISTRY.lock().unwrap();
let client = conn_map.get(conn_id).unwrap();  // Panic on None
```

**After (returns error to Elixir):**
```rust
let conn_map = safe_lock(&CONNECTION_REGISTRY, "context")?;
let client = conn_map.get(conn_id)
    .ok_or_else(|| rustler::Error::Term(Box::new("Connection not found")))?;
```

### Testing Error Handling

The library includes comprehensive error handling tests:

```bash
# Run error handling demonstration tests
mix test test/error_demo_test.exs test/error_handling_test.exs

# All tests (includes error handling tests)
mix test
```

These tests verify that all error conditions return proper error tuples and don't crash the VM.

### Best Practices

1. **Always pattern match on results:**
   ```elixir
   # Good
   case result do
     {:ok, data} -> handle_success(data)
     {:error, reason} -> handle_error(reason)
   end
   
   # Avoid - will crash if error
   {:ok, data} = result
   ```

2. **Use supervision trees:**
   ```elixir
   # Let processes crash, supervisor will restart
   def handle_cast(:do_query, state) do
     {:ok, result} = query!(state)  # Can crash this process
     {:noreply, update_state(result)}
   end
   ```

3. **Log errors with context:**
   ```elixir
   {:error, reason} = result
   Logger.error("Database operation failed", 
     error: reason,
     sql: sql,
     params: params
   )
   ```

4. **Consider circuit breakers for remote connections:**
   ```elixir
   # Use libraries like :fuse for circuit breaker pattern
   case :fuse.ask(:database_circuit, :sync) do
     :ok -> 
       case query(sql, params) do
         {:ok, result} -> {:ok, result}
         {:error, reason} -> 
           :fuse.melt(:database_circuit)
           {:error, reason}
       end
     :blown ->
       {:error, :circuit_breaker_open}
   end
   ```

### Performance Impact

The error handling improvements have **no performance impact** on the happy path. Error handling overhead is only incurred when actual errors occur, where it's negligible compared to the error handling time itself.

### Further Reading

- [Error Handling Demo Tests](test/error_demo_test.exs) - See concrete examples
- [Elixir Error Handling](https://hexdocs.pm/elixir/try-catch-and-rescue.html) - Official Elixir guide

---

## Troubleshooting

### Common Errors

#### "nif_not_loaded"

**Problem:** NIF functions not properly loaded.

**Solution:**
```elixir
# Make sure to recompile native code
mix deps.clean libsqlex --build
mix deps.get
mix compile
```

#### "database is locked"

**Problem:** SQLite write lock conflict.

**Solution:**
```elixir
# Use IMMEDIATE transactions for write-heavy workloads
{:ok, state} = EctoLibSql.Native.begin(state, behavior: :immediate)

# Or increase timeout in DBConnection
{:ok, conn} = DBConnection.start_link(
  EctoLibSql,
  [database: "myapp.db"],
  timeout: 15_000  # 15 seconds
)
```

#### "no such table"

**Problem:** Table doesn't exist or wrong database.

**Solution:**
```elixir
# Check connection mode
IO.inspect(state.mode)  # Should be :local, :remote, or :remote_replica

# Verify database file
File.exists?("myapp.db")

# Create table if not exists
{:ok, _, _, state} = EctoLibSql.handle_execute(
  "CREATE TABLE IF NOT EXISTS users (...)",
  [],
  [],
  state
)
```

#### Vector search not working

**Problem:** Invalid vector dimensions or format.

**Solution:**
```elixir
# Make sure vector dimensions match
vector_col = EctoLibSql.Native.vector_type(1536, :f32)  # Must match embedding size

# Verify embedding is a list of numbers
embedding = [1.0, 2.0, 3.0, ...]  # Not a string!
vec = EctoLibSql.Native.vector(embedding)

# Use vector() function in SQL
"INSERT INTO docs (embedding) VALUES (vector(?))", [vec]
```

### Debugging Tips

```elixir
# Enable query logging
defmodule MyApp.LoggingRepo do
  def query(sql, params, state) do
    IO.puts("SQL: #{sql}")
    IO.inspect(params, label: "Params")

    result = EctoLibSql.handle_execute(sql, params, [], state)

    IO.inspect(result, label: "Result")
    result
  end
end

# Check connection state
IO.inspect(state)
# %EctoLibSql.State{
#   conn_id: "uuid",
#   mode: :local,
#   sync: true,
#   trx_id: nil
# }

# Verify metadata
rowid = EctoLibSql.Native.get_last_insert_rowid(state)
changes = EctoLibSql.Native.get_changes(state)
total = EctoLibSql.Native.get_total_changes(state)
autocommit = EctoLibSql.Native.get_is_autocommit(state)

IO.inspect(%{
  last_rowid: rowid,
  changes: changes,
  total_changes: total,
  autocommit: autocommit
})
```

---

## Contributing

Found a bug or have a feature request? Please open an issue on GitHub!

## License

Apache 2.0
