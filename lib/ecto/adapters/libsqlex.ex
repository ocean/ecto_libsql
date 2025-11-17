defmodule Ecto.Adapters.LibSqlEx do
  @moduledoc """
  Ecto adapter for LibSQL/Turso databases.

  This adapter leverages the libsqlex library to provide full Ecto support
  for LibSQL databases, including local SQLite, remote Turso, and remote replica modes.

  ## Example Configuration

      config :my_app, MyApp.Repo,
        adapter: Ecto.Adapters.LibSqlEx,
        database: "my_app.db"

  ## Remote Turso Configuration

      config :my_app, MyApp.Repo,
        adapter: Ecto.Adapters.LibSqlEx,
        uri: "libsql://your-database.turso.io",
        auth_token: "your-auth-token"

  ## Remote Replica Configuration

      config :my_app, MyApp.Repo,
        adapter: Ecto.Adapters.LibSqlEx,
        database: "replica.db",
        uri: "libsql://your-database.turso.io",
        auth_token: "your-auth-token",
        sync: true

  ## Options

    * `:database` - The path to the local database file (for local or replica mode)
    * `:uri` - The URI for the remote Turso database
    * `:auth_token` - Authentication token for Turso
    * `:sync` - Auto-sync for replica mode (default: true)
    * `:encryption_key` - Encryption key for local database encryption
  """

  use Ecto.Adapters.SQL,
    driver: :libsqlex,
    migration_lock: nil

  @behaviour Ecto.Adapter.Storage
  @behaviour Ecto.Adapter.Structure
  @behaviour Ecto.Adapter.Migration

  ## Adapter Configuration

  @impl Ecto.Adapter
  defmacro __before_compile__(_env), do: :ok

  @doc false
  def connection, do: Ecto.Adapters.LibSqlEx.Connection

  ## Storage API

  @impl Ecto.Adapter.Storage
  def storage_up(opts) do
    database = Keyword.fetch!(opts, :database)

    # For remote-only mode (no local database), storage is managed by Turso
    if Keyword.has_key?(opts, :uri) && !Keyword.has_key?(opts, :database) do
      {:error, :already_up}
    else
      # For local or replica mode, create the database file
      case File.exists?(database) do
        true ->
          {:error, :already_up}

        false ->
          # Connect to create the database
          case LibSqlEx.connect(opts) do
            {:ok, state} ->
              LibSqlEx.disconnect([], state)
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

    case System.cmd("sqlite3", [database, ".schema"]) do
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
        {:ok, state} = LibSqlEx.connect(config)
        {:ok, _result, _state} = LibSqlEx.handle_execute(sql, [], [], state)
        LibSqlEx.disconnect([], state)
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
  def loaders(:binary_id, type), do: [Ecto.UUID, type]
  def loaders(:utc_datetime, type), do: [&datetime_decode/1, type]
  def loaders(:naive_datetime, type), do: [&datetime_decode/1, type]
  def loaders(:date, type), do: [&date_decode/1, type]
  def loaders(:time, type), do: [&time_decode/1, type]
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

  @doc false
  def dumpers(:binary, type), do: [type, &blob_encode/1]
  def dumpers(:binary_id, type), do: [type, Ecto.UUID]
  def dumpers(:boolean, type), do: [type, &bool_encode/1]
  def dumpers(:utc_datetime, type), do: [type, &datetime_encode/1]
  def dumpers(:naive_datetime, type), do: [type, &datetime_encode/1]
  def dumpers(:date, type), do: [type, &date_encode/1]
  def dumpers(:time, type), do: [type, &time_encode/1]
  def dumpers(_primitive, type), do: [type]

  defp blob_encode(value), do: {:ok, {:blob, value}}
  defp bool_encode(false), do: {:ok, 0}
  defp bool_encode(true), do: {:ok, 1}

  defp datetime_encode(%NaiveDateTime{} = datetime) do
    {:ok, NaiveDateTime.to_iso8601(datetime)}
  end

  defp date_encode(%Date{} = date) do
    {:ok, Date.to_iso8601(date)}
  end

  defp time_encode(%Time{} = time) do
    {:ok, Time.to_iso8601(time)}
  end
end
