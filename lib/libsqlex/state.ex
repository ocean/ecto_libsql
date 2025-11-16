defmodule LibSqlEx.State do
  @enforce_keys [:conn_id]

  defstruct [
    :conn_id,
    :trx_id,
    :mode,
    :sync
  ]

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
