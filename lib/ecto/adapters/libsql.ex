defmodule Ecto.Adapters.LibSql do
  @moduledoc """
  Ecto adapter for LibSQL and Turso databases.

  This adapter provides full Ecto support for LibSQL databases, including
  local SQLite files, remote Turso cloud databases, and embedded replicas
  that sync between local and remote.

  ## Connection Modes

  The adapter automatically detects the connection mode based on configuration:

  - **Local**: Only `:database` specified - uses local SQLite file
  - **Remote**: `:uri` and `:auth_token` specified - connects directly to Turso
  - **Remote Replica**: All of `:database`, `:uri`, `:auth_token`, and `:sync` specified -
    maintains local copy with automatic sync to remote

  ## Configuration Examples

  ### Local Database

      config :my_app, MyApp.Repo,
        adapter: Ecto.Adapters.LibSql,
        database: "my_app.db"

  ### Remote Turso Database

      config :my_app, MyApp.Repo,
        adapter: Ecto.Adapters.LibSql,
        uri: "libsql://your-database.turso.io",
        auth_token: "your-auth-token"

  ### Embedded Replica (Local + Remote Sync)

      config :my_app, MyApp.Repo,
        adapter: Ecto.Adapters.LibSql,
        database: "replica.db",
        uri: "libsql://your-database.turso.io",
        auth_token: "your-auth-token",
        sync: true

  ### With Encryption

      config :my_app, MyApp.Repo,
        adapter: Ecto.Adapters.LibSql,
        database: "encrypted.db",
        encryption_key: "your-secret-key-must-be-at-least-32-characters"

  ## Configuration Options

  - `:database` - Path to local SQLite database file
  - `:uri` - Remote LibSQL server URI (e.g., `"libsql://your-db.turso.io"`)
  - `:auth_token` - Authentication token for remote connections
  - `:sync` - Enable automatic sync for embedded replicas (boolean, default: `true` when in replica mode)
  - `:encryption_key` - Encryption key for local database (minimum 32 characters)

  ## Features

  - Full Ecto query support (schemas, changesets, associations, etc.)
  - Migration support with DDL transactions
  - SQLite-compatible data types with Ecto type conversions
  - Constraint violation detection and error handling
  - Storage management (`mix ecto.create`, `mix ecto.drop`, etc.)
  - Structure dump/load support

  ## Limitations

  - No advisory locking for migrations (SQLite uses database-level locking)
  - `Repo.stream/2` is not yet implemented (use DBConnection cursor interface instead)
  - Some advanced PostgreSQL/MySQL features may not be available
  - Vector search requires LibSQL-specific syntax

  """

  use Ecto.Adapters.SQL,
    driver: :ecto_libsql,
    migration_lock: nil

  @behaviour Ecto.Adapter.Storage
  @behaviour Ecto.Adapter.Structure

  ## Adapter Configuration

  @impl Ecto.Adapter
  defmacro __before_compile__(_env), do: :ok

  @doc false
  def connection, do: Ecto.Adapters.LibSql.Connection

  @impl Ecto.Adapter.Schema
  def autogenerate(:id), do: nil
  def autogenerate(:binary_id), do: Ecto.UUID.generate()
  def autogenerate(:embed_id), do: Ecto.UUID.generate()

  ## Storage API

  @impl Ecto.Adapter.Storage
  def storage_up(opts) do
    # For remote-only mode (no local database), storage is managed by Turso
    if Keyword.has_key?(opts, :uri) && !Keyword.has_key?(opts, :database) do
      {:error, :already_up}
    else
      database = Keyword.fetch!(opts, :database)

      # For local or replica mode, create the database file
      case File.exists?(database) do
        true ->
          {:error, :already_up}

        false ->
          # Connect to create the database
          case EctoLibSql.connect(opts) do
            {:ok, state} ->
              EctoLibSql.disconnect([], state)
              :ok

            {:error, reason} ->
              {:error, reason}
          end
      end
    end
  end

  @impl Ecto.Adapter.Storage
  def storage_down(opts) do
    database = Keyword.get(opts, :database)

    # For remote-only mode, can't drop remote storage
    if is_nil(database) do
      {:error, :not_supported}
    else
      case File.rm(database) do
        :ok -> :ok
        {:error, :enoent} -> {:error, :already_down}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl Ecto.Adapter.Storage
  def storage_status(opts) do
    database = Keyword.get(opts, :database)

    # For remote-only mode
    if is_nil(database) do
      :up
    else
      if File.exists?(database), do: :up, else: :down
    end
  end

  ## Structure API

  @impl Ecto.Adapter.Structure
  def structure_dump(default, config) do
    path = config[:dump_path] || Path.join(default, "structure.sql")
    database = Keyword.fetch!(config, :database)

    File.mkdir_p!(Path.dirname(path))

    # Clear environment to avoid leaking sensitive variables to subprocess.
    case System.cmd("sqlite3", [database, ".schema"], env: []) do
      {output, 0} ->
        File.write!(path, output)
        {:ok, path}

      {output, _} ->
        {:error, output}
    end
  end

  @impl Ecto.Adapter.Structure
  def structure_load(default, config) do
    path = config[:dump_path] || Path.join(default, "structure.sql")
    _database = Keyword.fetch!(config, :database)

    case File.read(path) do
      {:ok, sql} ->
        # Connect and execute the schema
        {:ok, state} = EctoLibSql.connect(config)
        {:ok, _result, _state} = EctoLibSql.handle_execute(sql, [], [], state)
        EctoLibSql.disconnect([], state)
        {:ok, path}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Ecto.Adapter.Structure
  def dump_cmd(_args, _opts, config) do
    database = Keyword.fetch!(config, :database)
    path = config[:dump_path] || "structure.sql"
    {:ok, ["sqlite3", database, ".schema"], [path]}
  end

  ## Migration API

  @impl Ecto.Adapter.Migration
  def supports_ddl_transaction?, do: true

  @impl Ecto.Adapter.Migration
  def lock_for_migrations(_meta, _opts, fun) do
    # SQLite uses database-level locking, so we just execute the function
    fun.()
  end

  ## Connection Helpers

  @doc false
  def loaders(:boolean, type), do: [&bool_decode/1, type]
  def loaders(:binary_id, type), do: [type]
  def loaders(:utc_datetime, type), do: [&datetime_decode/1, type]
  def loaders(:utc_datetime_usec, type), do: [&datetime_decode/1, type]
  def loaders(:naive_datetime, type), do: [&datetime_decode/1, type]
  def loaders(:naive_datetime_usec, type), do: [&datetime_decode/1, type]
  def loaders(:date, type), do: [&date_decode/1, type]
  def loaders(:time, type), do: [&time_decode/1, type]
  def loaders(:time_usec, type), do: [&time_decode/1, type]
  def loaders(:decimal, type), do: [&decimal_decode/1, type]
  def loaders(:json, type), do: [&json_decode/1, type]
  def loaders(:map, type), do: [&json_decode/1, type]
  def loaders({:array, _}, type), do: [&json_array_decode/1, type]
  def loaders(_primitive, type), do: [type]

  defp bool_decode(0), do: {:ok, false}
  defp bool_decode(1), do: {:ok, true}
  defp bool_decode(x), do: {:ok, x}

  defp datetime_decode(value) when is_binary(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _} -> :error
    end
  end

  defp datetime_decode(value), do: {:ok, value}

  defp date_decode(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> :error
    end
  end

  defp date_decode(value), do: {:ok, value}

  defp time_decode(value) when is_binary(value) do
    case Time.from_iso8601(value) do
      {:ok, time} -> {:ok, time}
      {:error, _} -> :error
    end
  end

  defp time_decode(value), do: {:ok, value}

  defp decimal_decode(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> {:ok, decimal}
      _ -> :error
    end
  end

  defp decimal_decode(value) when is_integer(value) do
    {:ok, Decimal.new(value)}
  end

  defp decimal_decode(value) when is_float(value) do
    {:ok, Decimal.from_float(value)}
  end

  defp decimal_decode(value), do: {:ok, value}

  defp json_decode(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> :error
    end
  end

  defp json_decode(value) when is_map(value), do: {:ok, value}
  defp json_decode(value), do: {:ok, value}

  defp json_array_decode(value) when is_binary(value) do
    case value do
      # Empty string defaults to empty array
      "" ->
        {:ok, []}

      _ ->
        case Jason.decode(value) do
          {:ok, decoded} when is_list(decoded) -> {:ok, decoded}
          {:ok, _} -> :error
          {:error, _} -> :error
        end
    end
  end

  defp json_array_decode(value) when is_list(value), do: {:ok, value}
  defp json_array_decode(_value), do: :error

  @doc false
  def dumpers(:binary, type), do: [type]
  def dumpers(:binary_id, type), do: [type]
  def dumpers(:boolean, type), do: [type, &bool_encode/1]
  def dumpers(:utc_datetime, type), do: [type, &datetime_encode/1]
  def dumpers(:utc_datetime_usec, type), do: [type, &datetime_encode/1]
  def dumpers(:naive_datetime, type), do: [type, &datetime_encode/1]
  def dumpers(:naive_datetime_usec, type), do: [type, &datetime_encode/1]
  def dumpers(:date, type), do: [type, &date_encode/1]
  def dumpers(:time, type), do: [type, &time_encode/1]
  def dumpers(:time_usec, type), do: [type, &time_encode/1]
  def dumpers(:decimal, type), do: [type, &decimal_encode/1]
  def dumpers(:json, type), do: [type, &json_encode/1]
  def dumpers(:map, type), do: [type, &json_encode/1]
  def dumpers({:array, _}, type), do: [type, &array_encode/1]
  def dumpers(_primitive, type), do: [type]

  defp bool_encode(false), do: {:ok, 0}
  defp bool_encode(true), do: {:ok, 1}

  defp datetime_encode(nil) do
    {:ok, nil}
  end

  defp datetime_encode(%DateTime{} = datetime) do
    {:ok, DateTime.to_iso8601(datetime)}
  end

  defp datetime_encode(%NaiveDateTime{} = datetime) do
    {:ok, NaiveDateTime.to_iso8601(datetime)}
  end

  defp date_encode(%Date{} = date) do
    {:ok, Date.to_iso8601(date)}
  end

  defp time_encode(%Time{} = time) do
    {:ok, Time.to_iso8601(time)}
  end

  defp decimal_encode(%Decimal{} = decimal) do
    {:ok, Decimal.to_string(decimal)}
  end

  defp json_encode(nil), do: {:ok, nil}

  defp json_encode(value) when is_binary(value), do: {:ok, value}

  defp json_encode(value) when is_map(value) or is_list(value) do
    case Jason.encode(value) do
      {:ok, json} -> {:ok, json}
      {:error, _} -> :error
    end
  end

  defp json_encode(value), do: {:ok, value}

  defp array_encode(value) when is_list(value) do
    case Jason.encode(value) do
      {:ok, json} -> {:ok, json}
      {:error, _} -> :error
    end
  end

  defp array_encode(value), do: {:ok, value}
end
