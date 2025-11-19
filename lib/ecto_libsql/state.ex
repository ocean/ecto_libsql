defmodule EctoLibSql.State do
  @moduledoc """
  Maintains the connection state for a LibSQL database connection.

  This struct tracks the current connection state including the connection ID,
  active transaction ID (if any), connection mode, and sync settings.

  ## Fields

  - `:conn_id` - Unique identifier for the connection (required)
  - `:trx_id` - Transaction ID if a transaction is active, `nil` otherwise
  - `:mode` - Connection mode (`:local`, `:remote`, or `:remote_replica`)
  - `:sync` - Sync mode for replicas (`:enable_sync` or `:disable_sync`)

  ## Connection Modes

  - **`:local`** - Local SQLite file
  - **`:remote`** - Direct connection to remote Turso database
  - **`:remote_replica`** - Local SQLite file with remote sync enabled

  """

  @enforce_keys [:conn_id]

  defstruct [
    :conn_id,
    :trx_id,
    :mode,
    :sync
  ]

  @doc """
  Detects the connection mode based on provided options.

  ## Examples

      iex> EctoLibSql.State.detect_mode(database: "local.db")
      :local

      iex> EctoLibSql.State.detect_mode(uri: "libsql://...", auth_token: "...")
      :remote

      iex> EctoLibSql.State.detect_mode(database: "local.db", uri: "libsql://...", auth_token: "...", sync: true)
      :remote_replica

  """
  def detect_mode(opts) do
    uri = Keyword.get(opts, :uri)
    token = Keyword.get(opts, :auth_token)
    db = Keyword.get(opts, :database)
    sync = Keyword.get(opts, :sync)

    cond do
      uri != nil and token != nil and db != nil and sync != nil -> :remote_replica
      uri != nil and token != nil -> :remote
      db != nil -> :local
      true -> :unknown
    end
  end

  @doc """
  Detects the sync mode based on provided options.

  Returns `:enable_sync` if sync is explicitly set to `true`,
  `:disable_sync` otherwise.
  """
  def detect_sync(opts) do
    has_sync = Keyword.has_key?(opts, :sync)

    case has_sync do
      true -> get_sync(Keyword.get(opts, :sync))
      false -> :disable_sync
    end
  end

  defp get_sync(val) do
    case val do
      true -> :enable_sync
      false -> :disable_sync
    end
  end
end
