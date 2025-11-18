# EctoLibSql

EctoLibSql is an unofficial Elixir database adapter built on top of Rust NIFs, providing a native driver connection to libSQL/Turso. It supports Local, Remote Replica, and Remote Only modes via configuration options.

## Features

- ✅ **Multiple Connection Modes**: Local, Remote, and Remote Replica
- ✅ **Batch Operations**: Execute multiple statements efficiently
- ✅ **Prepared Statements**: Reusable compiled SQL statements for better performance
- ✅ **Transaction Behaviors**: DEFERRED, IMMEDIATE, EXCLUSIVE, and READ_ONLY
- ✅ **Metadata Methods**: Access last_insert_rowid, changes, and total_changes
- ✅ **Auto/Manual Sync**: Automatic or manual synchronization for replicas
- ✅ **Parameterized Queries**: Safe parameter binding
- ✅ **Cursor Support**: Stream large result sets with DBConnection cursors
- ✅ **Vector Search**: Built-in vector similarity search with helper functions
- ✅ **Encryption**: AES-256-CBC encryption for local databases and replicas
- ✅ **WebSocket Support**: Use WebSocket (wss://) or HTTP (https://) protocols
- ✅ **libSQL 0.9.27**: Latest libSQL Rust crate with encryption feature 

## Installation

the package can be installed
by adding `ecto_libsql` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ecto_libsql, "~> 0.2.0"}
  ]
end
```

## Basic Usage

```elixir
defmodule Example do
  def run_query do
    # Connect to the database via remote replica
    opts = [
      uri: System.get_env("LIBSQL_URI"),
      auth_token: System.get_env("LIBSQL_TOKEN"),
      database: "bar.db",
      sync: true  # Enable auto-sync
    ]

    case EctoLibSql.connect(opts) do
      {:ok, state} ->
        # Create table
        query = "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)"
        {:ok, _result, state} = EctoLibSql.handle_execute(query, [], [], state)

        # Insert data
        {:ok, _result, state} = EctoLibSql.handle_execute(
          "INSERT INTO users (name) VALUES (?)",
          ["Alice"],
          [],
          state
        )

        # Query data
        {:ok, result, _state} = EctoLibSql.handle_execute(
          "SELECT * FROM users",
          [],
          [],
          state
        )
        IO.inspect(result)

      {:error, reason} ->
        IO.puts("Failed to connect: #{inspect(reason)}")
    end
  end
end
```

## Advanced Features

### Batch Operations

Execute multiple statements in one roundtrip:

```elixir
# Non-transactional batch (each statement independent)
statements = [
  {"INSERT INTO users (name) VALUES (?)", ["Alice"]},
  {"INSERT INTO users (name) VALUES (?)", ["Bob"]},
  {"SELECT * FROM users", []}
]
{:ok, results} = EctoLibSql.Native.batch(state, statements)

# Transactional batch (all-or-nothing)
{:ok, results} = EctoLibSql.Native.batch_transactional(state, statements)
```

### Prepared Statements

Reuse compiled SQL for better performance:

```elixir
# Prepare a statement
{:ok, stmt_id} = EctoLibSql.Native.prepare(state, "SELECT * FROM users WHERE id = ?")

# Execute it multiple times
{:ok, result1} = EctoLibSql.Native.query_stmt(state, stmt_id, [1])
{:ok, result2} = EctoLibSql.Native.query_stmt(state, stmt_id, [2])

# Clean up
:ok = EctoLibSql.Native.close_stmt(stmt_id)
```

### Transaction Behaviors

Control transaction locking and concurrency:

```elixir
# DEFERRED (default) - lock acquired on first write
{:ok, state} = EctoLibSql.Native.begin(state, behavior: :deferred)

# IMMEDIATE - lock acquired immediately
{:ok, state} = EctoLibSql.Native.begin(state, behavior: :immediate)

# EXCLUSIVE - exclusive lock, blocks all readers
{:ok, state} = EctoLibSql.Native.begin(state, behavior: :exclusive)

# READ_ONLY - read-only transaction
{:ok, state} = EctoLibSql.Native.begin(state, behavior: :read_only)
```

### Metadata Methods

Access database metadata:

```elixir
# Get last inserted row ID
rowid = EctoLibSql.Native.get_last_insert_rowid(state)

# Get number of changes from last operation
changes = EctoLibSql.Native.get_changes(state)

# Get total changes since connection opened
total = EctoLibSql.Native.get_total_changes(state)

# Check if in autocommit mode
autocommit? = EctoLibSql.Native.get_is_autocommit(state)
```

### Cursor Support

For streaming large result sets without loading everything into memory:

```elixir
{:ok, conn} = DBConnection.start_link(EctoLibSql, opts)

# Use stream to paginate through large datasets
DBConnection.stream(conn, %EctoLibSql.Query{statement: "SELECT * FROM large_table"}, [])
|> Stream.each(fn result ->
  IO.puts("Got #{result.num_rows} rows")
end)
|> Stream.run()
```

The cursor automatically fetches rows in chunks (default 500 rows per fetch).

### Vector Search

Built-in support for vector similarity search:

```elixir
# Create table with vector column
vector_col = EctoLibSql.Native.vector_type(3)  # 3-dimensional vectors
sql = "CREATE TABLE items (id INT, embedding #{vector_col})"
EctoLibSql.handle_execute(sql, [], [], state)

# Insert vectors
vec = EctoLibSql.Native.vector([1.0, 2.0, 3.0])
sql = "INSERT INTO items (id, embedding) VALUES (?, vector(?))"
EctoLibSql.handle_execute(sql, [1, vec], [], state)

# Search by similarity (cosine distance)
query_vec = [1.5, 2.1, 2.9]
distance_sql = EctoLibSql.Native.vector_distance_cos("embedding", query_vec)
sql = "SELECT * FROM items ORDER BY #{distance_sql} LIMIT 10"
{:ok, results, _} = EctoLibSql.handle_execute(sql, [], [], state)
```

### Encryption

Encrypt local databases and replicas with AES-256-CBC:

```elixir
# Local encrypted database
opts = [
  database: "encrypted.db",
  encryption_key: "your-secret-key-at-least-32-chars-long"
]
{:ok, state} = EctoLibSql.connect(opts)

# Encrypted remote replica
opts = [
  uri: "libsql://your-database.turso.io",
  auth_token: "your-token",
  database: "encrypted_replica.db",
  encryption_key: "your-secret-key-at-least-32-chars-long",
  sync: true
]
{:ok, state} = EctoLibSql.connect(opts)
```

**Security Note**: Store encryption keys securely (environment variables, secret management systems). The local database file will be encrypted at rest.

### WebSocket Protocol

Use WebSocket for lower latency and multiplexing by changing the URI scheme:

```elixir
# HTTP (default)
opts = [
  uri: "https://your-database.turso.io",
  auth_token: "your-token"
]

# WebSocket (lower latency, multiplexing)
opts = [
  uri: "wss://your-database.turso.io",
  auth_token: "your-token"
]
{:ok, state} = EctoLibSql.connect(opts)
```

libSQL automatically selects the protocol based on the URI scheme (https:// vs wss://)

## Local Opts
```elixir
    opts = [
      database: "bar.db",
    ]

```

## Remote Only Opts
```elixir

    opts = [
      uri: System.get_env("LIBSQL_URI"),
      auth_token: System.get_env("LIBSQL_TOKEN"),
    ]
```

### Manual Sync

For remote replica mode with manual sync control:

```elixir
opts = [
  uri: System.get_env("LIBSQL_URI"),
  auth_token: System.get_env("LIBSQL_TOKEN"),
  database: "bar.db",
  sync: false  # Disable auto-sync
]

{:ok, state} = EctoLibSql.connect(opts)

# Make changes
{:ok, _result, state} = EctoLibSql.handle_execute(
  "INSERT INTO users (name) VALUES (?)",
  ["Alice"],
  [],
  state
)

# Manually sync when ready
{:ok, _} = EctoLibSql.Native.sync(state)
```

## Connection Modes

### Local Mode
```elixir
opts = [database: "local.db"]
{:ok, state} = EctoLibSql.connect(opts)
```

### Remote Only Mode
```elixir
opts = [
  uri: "libsql://your-database.turso.io",
  auth_token: "your-auth-token"
]
{:ok, state} = EctoLibSql.connect(opts)
```

### Remote Replica Mode
```elixir
opts = [
  uri: "libsql://your-database.turso.io",
  auth_token: "your-auth-token",
  database: "local_replica.db",
  sync: true  # or false for manual sync
]
{:ok, state} = EctoLibSql.connect(opts)
```

## Performance Tips

1. **Use Prepared Statements** for queries executed multiple times
2. **Use Batch Operations** to reduce roundtrips for bulk operations
3. **Use Remote Replica Mode** for read-heavy workloads (microsecond latency)
4. **Use IMMEDIATE transactions** for write-heavy workloads to reduce lock contention
5. **Use WebSocket (wss://)** for lower latency and better multiplexing than HTTP
6. **Use Cursors** for large result sets to avoid loading everything into memory
7. **Disable auto-sync** and sync manually for better control in high-write scenarios
8. **Use Encryption** for sensitive data without performance penalty

## Documentation

Full documentation available at <https://hexdocs.pm/ecto_libsql>.
