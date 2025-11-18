defmodule EctoLibSql.State do
  @moduledoc """
  Connection state management for EctoLibSql.

  This module defines the connection state structure and provides utilities
  for detecting connection modes and synchronization settings based on the
  provided configuration options.

  ## Connection Modes

  The adapter supports three connection modes:

    * `:remote_replica` - Local database with remote replication enabled
    * `:remote` - Direct remote connection to a LibSQL server
    * `:local` - Local-only database file
    * `:unknown` - Mode could not be determined from options

  ## Fields

    * `:conn_id` - Unique identifier for the connection (required)
    * `:trx_id` - Transaction identifier when inside a transaction
    * `:mode` - Connection mode (`:remote_replica`, `:remote`, `:local`, or `:unknown`)
    * `:sync` - Synchronization setting (`:enable_sync` or `:disable_sync`)

  """

  @enforce_keys [:conn_id]

  defstruct [
    :conn_id,
    :trx_id,
    :mode,
    :sync
  ]

  @type mode :: :remote_replica | :remote | :local | :unknown
  @type sync :: :enable_sync | :disable_sync

  @type t :: %__MODULE__{
          conn_id: binary(),
          trx_id: binary() | nil,
          mode: mode() | nil,
          sync: sync() | nil
        }

  @doc """
  Detects the connection mode based on the provided options.

  The mode is determined by examining which connection options are provided:

    * If `:uri`, `:auth_token`, `:database`, and `:sync` are all present - `:remote_replica`
    * If only `:uri` and `:auth_token` are present - `:remote`
    * If only `:database` is present - `:local`
    * Otherwise - `:unknown`

  ## Examples

      iex> EctoLibSql.State.detect_mode(uri: "libsql://...", auth_token: "token", database: "local.db", sync: true)
      :remote_replica

      iex> EctoLibSql.State.detect_mode(database: "local.db")
      :local

  """
  @spec detect_mode(keyword()) :: mode()
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
  Detects the synchronization setting from the provided options.

  Returns `:enable_sync` if the `:sync` option is explicitly set to `true`,
  `:disable_sync` if set to `false` or not present.

  ## Examples

      iex> EctoLibSql.State.detect_sync(sync: true)
      :enable_sync

      iex> EctoLibSql.State.detect_sync([])
      :disable_sync

  """
  @spec detect_sync(keyword()) :: sync()
  def detect_sync(opts) do
    has_sync = Keyword.has_key?(opts, :sync)

    case has_sync do
      true -> get_sync(Keyword.get(opts, :sync))
      false -> :disable_sync
    end
  end

  @spec get_sync(boolean()) :: sync()
  defp get_sync(val) do
    case val do
      true -> :enable_sync
      false -> :disable_sync
    end
  end
end
