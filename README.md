# EctoLibSql

An Elixir database adapter for LibSQL and Turso, built with Rust NIFs. Supports local SQLite files, remote Turso databases, and embedded replicas with synchronization.

## Installation

Add `ecto_libsql` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ecto_libsql, "~> 0.2.0"}
  ]
end
```

## Quick Start

```elixir
# Local database
{:ok, conn} = DBConnection.start_link(EctoLibSql, database: "local.db")

# Remote Turso database
{:ok, conn} = DBConnection.start_link(EctoLibSql,
  uri: "libsql://your-db.turso.io",
  auth_token: "your-token"
)

# Embedded replica (local database synced with remote)
{:ok, conn} = DBConnection.start_link(EctoLibSql,
  database: "local.db",
  uri: "libsql://your-db.turso.io",
  auth_token: "your-token",
  sync: true
)
```

## Features

**Connection Modes**
- Local SQLite files
- Remote LibSQL/Turso servers
- Embedded replicas with automatic or manual sync

**Core Functionality**
- Parameterized queries with safe parameter binding
- Prepared statements
- Transactions with multiple isolation levels (deferred, immediate, exclusive)
- Batch operations (transactional and non-transactional)
- Streaming cursors for large result sets

**Advanced Features**
- Vector similarity search
- Database encryption (AES-256-CBC)
- WebSocket and HTTP protocols
- Metadata access (last insert ID, row counts, etc.)

## Usage Examples

### Basic Queries

```elixir
{:ok, conn} = DBConnection.start_link(EctoLibSql, database: "test.db")

# Create table
DBConnection.execute(conn, %EctoLibSql.Query{
  statement: "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)"
}, [])

# Insert with parameters
DBConnection.execute(conn, %EctoLibSql.Query{
  statement: "INSERT INTO users (name) VALUES (?)"
}, ["Alice"])

# Query data
{:ok, _query, result} = DBConnection.execute(conn, %EctoLibSql.Query{
  statement: "SELECT * FROM users WHERE name = ?"
}, ["Alice"])

IO.inspect(result.rows)  # [[1, "Alice"]]
```

### Transactions

```elixir
DBConnection.transaction(conn, fn conn ->
  DBConnection.execute(conn, %EctoLibSql.Query{
    statement: "INSERT INTO users (name) VALUES (?)"
  }, ["Bob"])

  DBConnection.execute(conn, %EctoLibSql.Query{
    statement: "INSERT INTO users (name) VALUES (?)"
  }, ["Carol"])
end)
```

### Prepared Statements

```elixir
# Prepare once, execute many times
{:ok, state} = EctoLibSql.connect(database: "test.db")

{:ok, stmt_id} = EctoLibSql.Native.prepare(state,
  "SELECT * FROM users WHERE id = ?")

{:ok, result1} = EctoLibSql.Native.query_stmt(state, stmt_id, [1])
{:ok, result2} = EctoLibSql.Native.query_stmt(state, stmt_id, [2])

:ok = EctoLibSql.Native.close_stmt(stmt_id)
```

### Batch Operations

```elixir
{:ok, state} = EctoLibSql.connect(database: "test.db")

# Execute multiple statements together
statements = [
  {"INSERT INTO users (name) VALUES (?)", ["Dave"]},
  {"INSERT INTO users (name) VALUES (?)", ["Eve"]},
  {"UPDATE users SET name = ? WHERE id = ?", ["David", 1]}
]

# Non-transactional (each statement independent)
{:ok, results} = EctoLibSql.Native.batch(state, statements)

# Transactional (all-or-nothing)
{:ok, results} = EctoLibSql.Native.batch_transactional(state, statements)
```

### Streaming Large Results

```elixir
{:ok, conn} = DBConnection.start_link(EctoLibSql, database: "test.db")

# Stream results in chunks to avoid loading everything into memory
stream = DBConnection.stream(conn,
  %EctoLibSql.Query{statement: "SELECT * FROM large_table"},
  [],
  max_rows: 1000
)

Enum.each(stream, fn result ->
  IO.puts("Processing #{result.num_rows} rows")
  # Process each chunk
end)
```

### Vector Similarity Search

```elixir
{:ok, state} = EctoLibSql.connect(database: "vectors.db")

# Create table with vector column (3 dimensions)
vector_type = EctoLibSql.Native.vector_type(3)
EctoLibSql.handle_execute(
  "CREATE TABLE items (id INTEGER, embedding #{vector_type})",
  [], [], state
)

# Insert vector
vec = EctoLibSql.Native.vector([1.0, 2.0, 3.0])
EctoLibSql.handle_execute(
  "INSERT INTO items VALUES (?, vector(?))",
  [1, vec], [], state
)

# Find similar vectors (cosine distance)
query_vector = [1.5, 2.1, 2.9]
distance_fn = EctoLibSql.Native.vector_distance_cos("embedding", query_vector)
{:ok, results, _} = EctoLibSql.handle_execute(
  "SELECT id FROM items ORDER BY #{distance_fn} LIMIT 10",
  [], [], state
)
```

### Database Encryption

```elixir
# Encrypted local database
{:ok, conn} = DBConnection.start_link(EctoLibSql,
  database: "encrypted.db",
  encryption_key: "your-secret-key-must-be-at-least-32-characters"
)

# Encrypted embedded replica
{:ok, conn} = DBConnection.start_link(EctoLibSql,
  database: "encrypted.db",
  uri: "libsql://your-db.turso.io",
  auth_token: "your-token",
  encryption_key: "your-secret-key-must-be-at-least-32-characters",
  sync: true
)
```

### Manual Sync Control

```elixir
# Disable automatic sync for embedded replicas
{:ok, state} = EctoLibSql.connect(
  database: "local.db",
  uri: "libsql://your-db.turso.io",
  auth_token: "your-token",
  sync: false
)

# Make local changes
EctoLibSql.handle_execute("INSERT INTO users (name) VALUES (?)", ["Alice"], [], state)

# Manually sync when ready
{:ok, _} = EctoLibSql.Native.sync(state)
```

## Configuration Options

| Option | Type | Description |
|--------|------|-------------|
| `database` | string | Path to local SQLite database file |
| `uri` | string | Remote LibSQL server URI (e.g., `libsql://...` or `wss://...`) |
| `auth_token` | string | Authentication token for remote connections |
| `sync` | boolean | Enable automatic sync for embedded replicas |
| `encryption_key` | string | Encryption key (32+ characters) for local database |

## Connection Modes

The adapter automatically detects the connection mode based on the options provided:

- **Local**: Only `database` specified
- **Remote**: `uri` and `auth_token` specified
- **Embedded Replica**: All of `database`, `uri`, `auth_token`, and `sync` specified

## Transaction Behaviors

Control transaction locking behavior:

```elixir
# Deferred (default) - locks acquired on first write
{:ok, state} = EctoLibSql.Native.begin(state, behavior: :deferred)

# Immediate - acquire write lock immediately
{:ok, state} = EctoLibSql.Native.begin(state, behavior: :immediate)

# Exclusive - acquire exclusive lock immediately
{:ok, state} = EctoLibSql.Native.begin(state, behavior: :exclusive)
```

## Metadata Functions

```elixir
# Get last inserted row ID
rowid = EctoLibSql.Native.get_last_insert_rowid(state)

# Get number of rows changed by last statement
changes = EctoLibSql.Native.get_changes(state)

# Get total rows changed since connection opened
total = EctoLibSql.Native.get_total_changes(state)

# Check if in autocommit mode (not in transaction)
autocommit? = EctoLibSql.Native.get_is_autocommit(state)
```

## Documentation

Full documentation is available at [https://hexdocs.pm/ecto_libsql](https://hexdocs.pm/ecto_libsql).

## License

Apache 2.0

## Credits

This library is a fork of [libsqlex](https://github.com/danawanb/libsqlex) by [danawanb](https://github.com/danawanb), extended from a DBConnection adapter to a full Ecto adapter with additional features including vector search, encryption, cursor support, and comprehensive documentation.
