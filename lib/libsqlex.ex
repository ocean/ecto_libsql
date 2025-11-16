defmodule LibSqlEx do
  @moduledoc """
  Documentation for `Libsqlex`.

  doesn't support handle_fetch, declare,  & deallocate

  ## Features

  - Connection handling via Rust NIF
  - Transaction support (`begin`, `commit`, `rollback`)
  - Query execution in both transactional and non-transactional contexts

  """

  use DBConnection

  @impl true
  @doc """
  Opens a connection to LibSQL using the native Rust layer.

  Returns `{:ok, state}` on success or `{:error, reason}` on failure. Automatically using remote replica if the opts provided database, uri, and auth token.
  """
  def connect(opts) do
    case LibSqlEx.Native.connect(opts, LibSqlEx.State.detect_mode(opts)) do
      conn_id when is_binary(conn_id) ->
        {:ok,
         %LibSqlEx.State{
           conn_id: conn_id,
           mode: LibSqlEx.State.detect_mode(opts),
           sync: LibSqlEx.State.detect_sync(opts)
         }}

      {:error, _} = err ->
        err

      other ->
        {:error, {:unexpected_response, other}}
    end
  end

  @impl true
  @doc """
  Pings the current connection to ensure it is still alive.
  """
  def ping(%LibSqlEx.State{conn_id: conn_id} = state) do
    case LibSqlEx.Native.ping(conn_id) do
      true -> {:ok, state}
      _ -> {:disconnect, :ping_failed, state}
    end
  end

  @impl true
  @doc """
  Disconnects from the database by closing the underlying native connection by deleting the connection registr.
  """
  def disconnect(_opts, %LibSqlEx.State{conn_id: conn_id, trx_id: _trx_id} = state) do
    # return :ok on success
    LibSqlEx.Native.close_conn(conn_id, :conn_id, state)
  end

  @impl true
  @doc """
  Executes an SQL query, delegating to transactional or non-transactional logic
  depending on the connection state.
  """
  def handle_execute(
        query,
        args,
        _opts,
        %LibSqlEx.State{conn_id: _conn_id, trx_id: trx_id, mode: _mode} = state
      ) do
    query_struct =
      case query do
        %LibSqlEx.Query{} -> query
        query when is_binary(query) -> %LibSqlEx.Query{statement: query}
      end

    if trx_id do
      LibSqlEx.Native.execute_with_trx(state, query_struct, args)
    else
      LibSqlEx.Native.execute_non_trx(query_struct, state, args)
    end
  end

  @impl true
  @doc """
  Begins a new database transaction.
  """
  def handle_begin(_opts, state) do
    case LibSqlEx.Native.begin(state) do
      {:ok, new_state} -> {:ok, :begin, new_state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  @impl true
  def handle_commit(_opts, %LibSqlEx.State{trx_id: nil} = state) do
    {:error, %RuntimeError{message: "no active transaction"}, state}
  end

  @impl true
  @doc """
  Commits the current transaction. The state must provide a uuid string of trx_id/transaction id
  """
  def handle_commit(_opts, state) do
    case LibSqlEx.Native.commit(
           %LibSqlEx.State{conn_id: conn_id, trx_id: _trx_id, mode: mode} = state
         ) do
      {:ok, _} ->
        {:ok, %LibSqlEx.Result{}, %LibSqlEx.State{conn_id: conn_id, mode: mode}}

      {:error, reason} ->
        {:disconnect, reason, state}
    end
  end

  @impl true
  @doc """
  Rollback the current transaction.
  """
  def handle_rollback(_opts, %LibSqlEx.State{conn_id: conn_id, trx_id: _trx_id} = state) do
    case LibSqlEx.Native.rollback(state) do
      {:ok, _} ->
        {:ok, %LibSqlEx.Result{}, %LibSqlEx.State{conn_id: conn_id, trx_id: nil}}

      {:error, reason} ->
        {:disconnect, reason, state}
    end
  end

  @impl true
  @doc """
  Closes the query. Currently a no-op.
  """
  def handle_close(_query, _opts, state) do
    {:ok, %LibSqlEx.Result{}, state}
  end

  @impl true
  def handle_status(_opts, %LibSqlEx.State{conn_id: _conn_id, trx_id: trx_id} = state) do
    case LibSqlEx.Native.handle_status_transaction(trx_id) do
      :ok -> {:transaction, state}
      {:error, message} -> {:disconnect, message, state}
    end
  end

  @impl true
  def handle_prepare(%LibSqlEx.Query{} = query, _opts, state) do
    {:ok, query, state}
  end

  @impl true
  def checkout(%LibSqlEx.State{conn_id: conn_id} = state) do
    case LibSqlEx.Native.ping(conn_id) do
      true -> {:ok, state}
      {:error, reason} -> {:disconnect, reason, state}
    end
  end

  @impl true
  def handle_fetch(%LibSqlEx.Query{} = _query, cursor, opts, %LibSqlEx.State{} = state) do
    max_rows = Keyword.get(opts, :max_rows, 500)

    case LibSqlEx.Native.fetch_cursor(cursor.ref, max_rows) do
      {columns, rows, _count} when is_list(rows) ->
        result = %LibSqlEx.Result{
          command: :select,
          columns: columns,
          rows: rows,
          num_rows: length(rows)
        }

        if length(rows) == 0 do
          # No more rows, deallocate cursor
          :ok = LibSqlEx.Native.close(cursor.ref, :cursor_id)
          {:deallocated, result, state}
        else
          {:cont, result, state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @impl true
  def handle_deallocate(_query, cursor, _opts, state) do
    case LibSqlEx.Native.close(cursor.ref, :cursor_id) do
      :ok ->
        {:ok, %LibSqlEx.Result{}, state}

      {:error, _reason} ->
        # Cursor might already be deallocated, that's ok
        {:ok, %LibSqlEx.Result{}, state}
    end
  end

  @impl true
  def handle_declare(
        %LibSqlEx.Query{statement: statement} = query,
        params,
        _opts,
        %LibSqlEx.State{conn_id: conn_id} = state
      ) do
    case LibSqlEx.Native.declare_cursor(conn_id, statement, params) do
      cursor_id when is_binary(cursor_id) ->
        cursor = %{ref: cursor_id}
        {:ok, query, cursor, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end
end
