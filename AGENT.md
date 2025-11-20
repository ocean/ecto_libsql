# ecto_libsql - Comprehensive Developer Guide

Welcome to ecto_libsql! This guide provides comprehensive documentation, API reference, and practical examples for building applications with LibSQL/Turso in Elixir using the Ecto adapter.

## Table of Contents

- [Quick Start](#quick-start)
- [Connection Management](#connection-management)
- [Basic Operations](#basic-operations)
- [Advanced Features](#advanced-features)
  - [Transactions](#transactions)
  - [Prepared Statements](#prepared-statements)
  - [Batch Operations](#batch-operations)
  - [Cursor Streaming](#cursor-streaming)
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
- [API Reference](#api-reference)
- [Real-World Examples](#real-world-examples)
- [Performance Guide](#performance-guide)
- [Troubleshooting](#troubleshooting)

---

## Quick Start

### Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:ecto_libsql, "~> 0.4.0"}
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

# Parameterized select
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

### Prepared Statements

Prepared statements offer better performance for repeated queries and prevent SQL injection.

#### Basic Prepared Statements

```elixir
# Prepare the statement
{:ok, stmt_id} = EctoLibSql.Native.prepare(
  state,
  "SELECT * FROM users WHERE email = ?"
)

# Execute multiple times with different parameters
{:ok, result1} = EctoLibSql.Native.query_stmt(state, stmt_id, ["alice@example.com"])
{:ok, result2} = EctoLibSql.Native.query_stmt(state, stmt_id, ["bob@example.com"])
{:ok, result3} = EctoLibSql.Native.query_stmt(state, stmt_id, ["charlie@example.com"])

# Clean up when done
:ok = EctoLibSql.Native.close_stmt(stmt_id)
```

#### Prepared INSERT/UPDATE/DELETE

```elixir
# Prepare an INSERT statement
{:ok, stmt_id} = EctoLibSql.Native.prepare(
  state,
  "INSERT INTO users (name, email) VALUES (?, ?)"
)

# Execute multiple inserts
{:ok, rows} = EctoLibSql.Native.execute_stmt(
  state,
  stmt_id,
  "INSERT INTO users (name, email) VALUES (?, ?)",
  ["User 1", "user1@example.com"]
)
IO.puts("Inserted #{rows} rows")

{:ok, rows} = EctoLibSql.Native.execute_stmt(
  state,
  stmt_id,
  "INSERT INTO users (name, email) VALUES (?, ?)",
  ["User 2", "user2@example.com"]
)

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

---

## Ecto Integration

EctoLibSql provides a full Ecto adapter, making it seamless to use with Phoenix and Ecto-based applications. This enables you to use all Ecto features including schemas, migrations, queries, and associations.

### Quick Start with Ecto

#### 1. Installation

Add `ecto_libsql` to your dependencies (it already includes `ecto_sql`):

```elixir
def deps do
  [
    {:ecto_libsql, "~> 0.4.0"}
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

Most Ecto migrations work perfectly. SQLite limitations:

```elixir
# ✅ SUPPORTED
create table(:users)
alter table(:users) do: add :field, :type
drop table(:users)
create index(:users, [:email])
rename table(:old), to: table(:new)
rename table(:users), :old_field, to: :new_field

# ❌ NOT SUPPORTED
alter table(:users) do: modify :field, :new_type  # Can't change column type
alter table(:users) do: remove :field  # Can't drop column (SQLite < 3.35.0)

# Workaround: Recreate table
defmodule MyApp.Repo.Migrations.ChangeUserAge do
  use Ecto.Migration

  def up do
    create table(:users_new) do
      # Define new schema
    end

    execute "INSERT INTO users_new SELECT * FROM users"
    drop table(:users)
    rename table(:users_new), to: table(:users)
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

#### `EctoLibSql.handle_deallocate/3`

Deallocates a cursor.

**Parameters:**
- `query` (EctoLibSql.Query): SQL query
- `cursor`: Cursor reference
- `opts` (keyword list): Options
- `state` (EctoLibSql.State): Connection state

**Returns:** `{:ok, result, state}` or `{:error, reason, state}`

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

### Sync Functions

#### `EctoLibSql.Native.sync/1`

Manually synchronises a remote replica.

**Parameters:**
- `state` (EctoLibSql.State): Connection state

**Returns:** `{:ok, message}` or `{:error, reason}`

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

### Optimizing Writes

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

### Query Optimization

```elixir
# Use prepared statements for repeated queries
defmodule MyApp.UserLookup do
  def setup(state) do
    {:ok, stmt} = EctoLibSql.Native.prepare(
      state,
      "SELECT * FROM users WHERE email = ?"
    )

    %{state: state, lookup_stmt: stmt}
  end

  # ❌ Slow: Prepare each time
  def slow_lookup(state, email) do
    {:ok, stmt} = EctoLibSql.Native.prepare(state, "SELECT * FROM users WHERE email = ?")
    {:ok, result} = EctoLibSql.Native.query_stmt(state, stmt, [email])
    EctoLibSql.Native.close_stmt(stmt)
    result
  end

  # ✅ Fast: Reuse prepared statement
  def fast_lookup(context, email) do
    {:ok, result} = EctoLibSql.Native.query_stmt(
      context.state,
      context.lookup_stmt,
      [email]
    )
    result
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
