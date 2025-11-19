# EctoLibSql

`ecto_libsql` is an (unofficial) Elixir Ecto database adapter for LibSQL and Turso, built with Rust NIFs. It supports local SQLite files, remote replica with synchronisation, and remote only [Turso](https://turso.tech/) databases.

## Installation

Add `ecto_libsql` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ecto_libsql, "~> 0.1.0"}
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
- Parameterised queries with safe parameter binding
- Prepared statements
- Transactions with multiple isolation levels (deferred, immediate, exclusive)
- Batch operations (transactional and non-transactional)
- Metadata access (last insert ID, row counts, etc.)

**Advanced Features**
- Vector similarity search
- WebSocket and HTTP protocols

## Documentation

Full documentation is available at [https://hexdocs.pm/ecto_libsql](https://hexdocs.pm/ecto_libsql).

## License

Apache 2.0

## Credits

This library is a fork of [libsqlex](https://github.com/danawanb/libsqlex) by [danawanb](https://github.com/danawanb), extended from a DBConnection adapter to a full Ecto adapter with additional features including vector search, encryption, cursor support, and comprehensive documentation.
