# EctoLibSql

[![GitHub Actions CI](https://github.com/ocean/ecto_libsql/actions/workflows/ci.yml/badge.svg)](https://github.com/ocean/ecto_libsql/actions/workflows/ci.yml)

`ecto_libsql` is an (unofficial) Elixir Ecto database adapter for LibSQL and Turso, built with Rust NIFs. It supports local libSQL/SQLite files, remote replica with synchronisation, and remote only [Turso](https://turso.tech/) databases.

## Installation

Add `ecto_libsql` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ecto_libsql, "~> 0.5.0"}
  ]
end
```

## Quick Start

### With Ecto (Recommended)

```elixir
# Configure your repo
config :my_app, MyApp.Repo,
  adapter: Ecto.Adapters.LibSql,
  database: "my_app.db"

# Define your repo
defmodule MyApp.Repo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.LibSql
end

# Use Ecto as normal
defmodule MyApp.User do
  use Ecto.Schema

  schema "users" do
    field :name, :string
    field :email, :string
    timestamps()
  end
end

# CRUD operations
{:ok, user} = MyApp.Repo.insert(%MyApp.User{name: "Alice", email: "alice@example.com"})
users = MyApp.Repo.all(MyApp.User)
```

### With DBConnection (Advanced)

For lower-level control, you can use the DBConnection interface directly:

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
- Embedded replicas with automatic or manual synchronisation

**Core Functionality**
- Parameterised queries with safe parameter binding
- Prepared statements
- Transactions with multiple isolation levels (deferred, immediate, exclusive)
- Batch operations (transactional and non-transactional)
- Metadata access (last insert ID, row counts, etc.)

**Advanced Features**
- Vector similarity search
- Database encryption (AES-256-CBC for local and embedded replica databases)
- WebSocket and HTTP protocols
- Cursor-based streaming for large result sets (via DBConnection interface)

**Note:** Ecto `Repo.stream()` is not yet implemented. For streaming large datasets, use the DBConnection cursor interface directly (see examples in AGENTS.md).

**Reliability**
- **Production-ready error handling**: All Rust NIF errors return proper Elixir error tuples instead of crashing the BEAM VM
- **Graceful degradation**: Invalid operations (bad connection IDs, missing resources) return `{:error, message}` for proper supervision tree handling

## Documentation

- **API Documentation**: [https://hexdocs.pm/ecto_libsql](https://hexdocs.pm/ecto_libsql)
- **LLM / AGENT Guide**: [AGENTS.md](AGENTS.md)
- **Changelog**: [CHANGELOG.md](CHANGELOG.md)
- **Migration Guide**: [ECTO_MIGRATION_GUIDE.md](ECTO_MIGRATION_GUIDE.md)

## Usage Examples

### Ecto Examples

#### Basic CRUD Operations

```elixir
# Setup
defmodule MyApp.Repo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.LibSql
end

defmodule MyApp.User do
  use Ecto.Schema

  schema "users" do
    field :name, :string
    field :email, :string
    field :age, :integer
    timestamps()
  end
end

# Create
{:ok, user} = MyApp.Repo.insert(%MyApp.User{
  name: "Alice",
  email: "alice@example.com",
  age: 30
})

# Read
user = MyApp.Repo.get(MyApp.User, 1)
users = MyApp.Repo.all(MyApp.User)

# Update
user
|> Ecto.Changeset.change(age: 31)
|> MyApp.Repo.update()

# Delete
MyApp.Repo.delete(user)
```

#### Queries with Ecto.Query

```elixir
import Ecto.Query

# Filter and order
adults = MyApp.User
  |> where([u], u.age >= 18)
  |> order_by([u], desc: u.inserted_at)
  |> MyApp.Repo.all()

# Aggregations
count = MyApp.User
  |> where([u], u.age >= 18)
  |> MyApp.Repo.aggregate(:count)

avg_age = MyApp.Repo.aggregate(MyApp.User, :avg, :age)
```

#### Transactions

```elixir
MyApp.Repo.transaction(fn ->
  {:ok, user1} = MyApp.Repo.insert(%MyApp.User{name: "Bob", email: "bob@example.com"})
  {:ok, user2} = MyApp.Repo.insert(%MyApp.User{name: "Carol", email: "carol@example.com"})

  %{user1: user1, user2: user2}
end)
```

### DBConnection Examples (Advanced)

For lower-level control, use the DBConnection interface:

#### Basic Queries

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

#### Transactions

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

### Vector Similarity Search

```elixir
{:ok, state} = EctoLibSql.connect(database: "vectors.db")

# Create table with vector column (3 dimensions, f32 precision)
vector_type = EctoLibSql.Native.vector_type(3, :f32)
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
{:ok, _query, results, _} = EctoLibSql.handle_execute(
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

### Embedded Replica Synchronisation

When using embedded replica mode (`sync: true`), the library automatically handles synchronisation between your local database and Turso cloud. However, you can also trigger manual sync when needed.

#### Automatic Sync Behaviour

```elixir
# Automatic sync is enabled with sync: true
{:ok, state} = EctoLibSql.connect(
  database: "local.db",
  uri: "libsql://your-db.turso.io",
  auth_token: "your-token",
  sync: true  # Automatic sync enabled
)

# Writes and reads work normally - sync happens automatically
EctoLibSql.handle_execute("INSERT INTO users (name) VALUES (?)", ["Alice"], [], state)
EctoLibSql.handle_execute("SELECT * FROM users", [], [], state)
```

**How automatic sync works:**
- Initial sync happens when you first connect
- Changes are synced automatically in the background
- You don't need to call `sync/1` in most applications

#### Manual Sync Control

For specific use cases, you can manually trigger synchronisation:

```elixir
# Force immediate sync after critical operation
EctoLibSql.handle_execute("INSERT INTO orders (total) VALUES (?)", [1000.00], [], state)
{:ok, _} = EctoLibSql.Native.sync(state)  # Ensure synced to cloud immediately

# Before shutdown - ensure all changes are persisted
{:ok, _} = EctoLibSql.Native.sync(state)
:ok = EctoLibSql.disconnect([], state)

# Coordinate between multiple replicas
{:ok, _} = EctoLibSql.Native.sync(replica1)  # Push local changes
{:ok, _} = EctoLibSql.Native.sync(replica2)  # Pull those changes on another replica
```

**When to use manual sync:**
- **Critical operations**: Immediately after writes that must be durable
- **Before shutdown**: Ensuring all local changes reach the cloud
- **Coordinating replicas**: When multiple replicas need consistent data immediately
- **After batch operations**: Following bulk inserts/updates

**When you DON'T need manual sync:**
- Normal application reads/writes (automatic sync handles this)
- Most CRUD operations (background sync is sufficient)
- Development and testing (automatic sync is fine)

#### Disabling Automatic Sync

You can disable automatic sync and rely entirely on manual control:

```elixir
# Disable automatic sync
{:ok, state} = EctoLibSql.connect(
  database: "local.db",
  uri: "libsql://your-db.turso.io",
  auth_token: "your-token",
  sync: false  # Manual sync only
)

# Make local changes (not synced yet)
EctoLibSql.handle_execute("INSERT INTO users (name) VALUES (?)", ["Alice"], [], state)

# Manually synchronise when ready
{:ok, _} = EctoLibSql.Native.sync(state)
```

This is useful for offline-first applications or when you want explicit control over when data syncs.

## Configuration Options

| Option | Type | Description |
|--------|------|-------------|
| `database` | string | Path to local SQLite database file |
| `uri` | string | Remote LibSQL server URI (e.g., `libsql://...` or `wss://...`) |
| `auth_token` | string | Authentication token for remote connections |
| `sync` | boolean | Enable automatic synchronisation for embedded replicas |
| `encryption_key` | string | Encryption key (32+ characters) for local database |

## Connection Modes

The adapter automatically detects the connection mode based on the options provided:

### Local Mode
Only `database` specified - stores data in a local SQLite file:

```elixir
config :my_app, MyApp.Repo,
  adapter: Ecto.Adapters.LibSql,
  database: "my_app.db"
```

### Remote Mode
`uri` and `auth_token` specified - connects directly to Turso cloud:

```elixir
config :my_app, MyApp.Repo,
  adapter: Ecto.Adapters.LibSql,
  uri: "libsql://your-database.turso.io",
  auth_token: System.get_env("TURSO_AUTH_TOKEN")
```

### Embedded Replica Mode (Recommended for Production)
All of `database`, `uri`, `auth_token`, and `sync` specified - local file with cloud synchronisation:

```elixir
config :my_app, MyApp.Repo,
  adapter: Ecto.Adapters.LibSql,
  database: "replica.db",
  uri: "libsql://your-database.turso.io",
  auth_token: System.get_env("TURSO_AUTH_TOKEN"),
  sync: true
```

This mode provides microsecond read latency (local file) with automatic cloud backup. Synchronisation happens automatically in the background - see the [Embedded Replica Synchronisation](#embedded-replica-synchronisation) section for details on sync behaviour and manual sync control.

## Transaction Behaviours

Control transaction locking behaviour:

```elixir
# Deferred (default) - locks acquired on first write
{:ok, state} = EctoLibSql.Native.begin(state, behavior: :deferred)

# Immediate - acquire write lock immediately
{:ok, state} = EctoLibSql.Native.begin(state, behavior: :immediate)

# Read-only - read lock only
{:ok, state} = EctoLibSql.Native.begin(state, behavior: :read_only)
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

## License

Apache 2.0

## Credits

This library is a fork of [libsqlex](https://github.com/danawanb/libsqlex) by [danawanb](https://github.com/danawanb), extended from a DBConnection adapter to a full Ecto adapter with additional features including vector similarity search, database encryption, batch operations, prepared statements, and comprehensive documentation.
