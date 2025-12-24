defmodule EctoLibSql do
  @moduledoc """
  DBConnection implementation for LibSQL and Turso databases.

  This module provides the core database connection functionality for LibSQL/Turso,
  implementing the `DBConnection` behaviour. It supports three connection modes:

  - **Local**: SQLite files on the local filesystem
  - **Remote**: Direct connections to Turso cloud databases
  - **Remote Replica**: Local SQLite files that sync with remote Turso databases

  ## Features

  - Connection management via Rust NIFs for high performance
  - Full transaction support with multiple isolation levels
  - Query execution in both transactional and non-transactional contexts
  - Cursor support for streaming large result sets
  - Prepared statement caching
  - Batch operations (transactional and non-transactional)
  - Vector similarity search
  - Database encryption

  ## Connection Options

  - `:database` - Path to local SQLite database file
  - `:uri` - Remote LibSQL server URI (e.g., `"libsql://your-db.turso.io"`)
  - `:auth_token` - Authentication token for remote connections
  - `:sync` - Enable automatic sync for embedded replicas (boolean)
  - `:encryption_key` - Encryption key for local database (min 32 characters)

  ## Examples

      # Local database
      {:ok, conn} = DBConnection.start_link(EctoLibSql, database: "local.db")

      # Remote Turso database
      {:ok, conn} = DBConnection.start_link(EctoLibSql,
        uri: "libsql://your-db.turso.io",
        auth_token: "your-token"
      )

      # Embedded replica (local + remote sync)
      {:ok, conn} = DBConnection.start_link(EctoLibSql,
        database: "local.db",
        uri: "libsql://your-db.turso.io",
        auth_token: "your-token",
        sync: true
      )

  """

  use DBConnection

  # Default busy timeout in milliseconds (5 seconds)
  @default_busy_timeout 5000

  @impl true
  @doc """
  Opens a connection to LibSQL using the native Rust layer.

  Returns `{:ok, state}` on success or `{:error, reason}` on failure.
  Automatically uses remote replica if the opts provided database, uri, and auth token.

  ## Options

  - `:database` - Path to local SQLite database file
  - `:uri` - Remote LibSQL server URI (e.g., `"libsql://your-db.turso.io"`)
  - `:auth_token` - Authentication token for remote connections
  - `:sync` - Enable automatic sync for embedded replicas (boolean)
  - `:encryption_key` - Encryption key for local database (min 32 characters)
  - `:busy_timeout` - Busy timeout in milliseconds (default: 5000)
                      Controls how long SQLite waits for locks before returning SQLITE_BUSY.
                      Set to 0 to disable (not recommended for production).

  """
  def connect(opts) do
    case EctoLibSql.Native.connect(opts, EctoLibSql.State.detect_mode(opts)) do
      conn_id when is_binary(conn_id) ->
        state = %EctoLibSql.State{
          conn_id: conn_id,
          mode: EctoLibSql.State.detect_mode(opts),
          sync: EctoLibSql.State.detect_sync(opts)
        }

        # Set busy_timeout for better concurrency handling
        busy_timeout = Keyword.get(opts, :busy_timeout, @default_busy_timeout)

        case EctoLibSql.Native.set_busy_timeout(conn_id, busy_timeout) do
          :ok ->
            {:ok, state}

          {:error, reason} ->
            # Log warning but don't fail connection - busy_timeout is an optimization
            require Logger
            Logger.warning("Failed to set busy_timeout: #{inspect(reason)}")
            {:ok, state}
        end

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
  def ping(%EctoLibSql.State{conn_id: conn_id} = state) do
    case EctoLibSql.Native.ping(conn_id) do
      true -> {:ok, state}
      _ -> {:disconnect, :ping_failed, state}
    end
  end

  @impl true
  @doc """
  Disconnects from the database by closing the underlying native connection.

  Removes the connection from the Rust connection registry and cleans up any resources.
  """
  def disconnect(_opts, %EctoLibSql.State{conn_id: conn_id, trx_id: _trx_id} = state) do
    # return :ok on success
    EctoLibSql.Native.close_conn(conn_id, :conn_id, state)
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
        %EctoLibSql.State{conn_id: _conn_id, trx_id: trx_id, mode: _mode} = state
      ) do
    query_struct =
      case query do
        %EctoLibSql.Query{} -> query
        query when is_binary(query) -> %EctoLibSql.Query{statement: query}
      end

    if trx_id do
      EctoLibSql.Native.execute_with_trx(state, query_struct, args)
    else
      EctoLibSql.Native.execute_non_trx(query_struct, state, args)
    end
  end

  @impl true
  @doc """
  Begins a new database transaction.

  The transaction behaviour (deferred/immediate/exclusive) can be controlled
  via options passed to the Native module.
  """
  def handle_begin(_opts, state) do
    case EctoLibSql.Native.begin(state) do
      {:ok, new_state} -> {:ok, :begin, new_state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  @impl true
  def handle_commit(_opts, %EctoLibSql.State{trx_id: nil} = state) do
    {:error, %RuntimeError{message: "no active transaction"}, state}
  end

  @impl true
  @doc """
  Commits the current transaction.

  The state must contain a valid transaction ID. For embedded replicas with
  auto-sync enabled, this will also trigger a sync to the remote database.
  """
  def handle_commit(_opts, state) do
    case EctoLibSql.Native.commit(
           %EctoLibSql.State{conn_id: conn_id, trx_id: _trx_id, mode: mode} = state
         ) do
      {:ok, _} ->
        {:ok, %EctoLibSql.Result{}, %EctoLibSql.State{conn_id: conn_id, mode: mode}}

      {:error, reason} ->
        {:disconnect, reason, state}
    end
  end

  @impl true
  @doc """
  Rolls back the current transaction.

  Discards all changes made within the transaction and returns the connection
  to autocommit mode.
  """
  def handle_rollback(_opts, %EctoLibSql.State{conn_id: conn_id, trx_id: _trx_id} = state) do
    case EctoLibSql.Native.rollback(state) do
      {:ok, _} ->
        {:ok, %EctoLibSql.Result{}, %EctoLibSql.State{conn_id: conn_id, trx_id: nil}}

      {:error, reason} ->
        {:disconnect, reason, state}
    end
  end

  @impl true
  @doc """
  Closes the query. Currently a no-op as queries are stateless.
  """
  def handle_close(_query, _opts, state) do
    {:ok, %EctoLibSql.Result{}, state}
  end

  @impl true
  @doc """
  Checks the current transaction status.
  """
  def handle_status(_opts, %EctoLibSql.State{conn_id: _conn_id, trx_id: trx_id} = state) do
    case trx_id do
      nil ->
        # No active transaction, connection is idle
        {:idle, state}

      trx_id when is_binary(trx_id) ->
        # Check if transaction is still active
        case EctoLibSql.Native.handle_status_transaction(trx_id) do
          :ok -> {:transaction, state}
          {:error, _message} -> {:idle, %{state | trx_id: nil}}
        end
    end
  end

  @impl true
  @doc """
  Prepares a query for execution. Returns the query unchanged as preparation
  is handled during execution.
  """
  def handle_prepare(%EctoLibSql.Query{} = query, _opts, state) do
    {:ok, query, state}
  end

  @impl true
  @doc """
  Checks out a connection from the pool by verifying it's still alive.
  """
  def checkout(%EctoLibSql.State{conn_id: conn_id} = state) do
    case EctoLibSql.Native.ping(conn_id) do
      true -> {:ok, state}
      {:error, reason} -> {:disconnect, reason, state}
    end
  end

  @impl true
  @doc """
  Fetches the next batch of rows from a cursor.

  Cursors are used for streaming large result sets without loading everything
  into memory at once. Automatically deallocates the cursor when no more rows
  are available.
  """
  def handle_fetch(
        %EctoLibSql.Query{} = _query,
        cursor,
        opts,
        %EctoLibSql.State{conn_id: conn_id} = state
      ) do
    max_rows = Keyword.get(opts, :max_rows, 500)

    case EctoLibSql.Native.fetch_cursor(conn_id, cursor.ref, max_rows) do
      {columns, rows, _count} when is_list(rows) ->
        result = %EctoLibSql.Result{
          command: :select,
          columns: columns,
          rows: rows,
          num_rows: length(rows)
        }

        if length(rows) == 0 do
          # No more rows, signal halt
          {:halt, result, state}
        else
          {:cont, result, state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @impl true
  @doc """
  Deallocates a cursor, freeing its resources.
  """
  def handle_deallocate(_query, cursor, _opts, state) do
    case EctoLibSql.Native.close(cursor.ref, :cursor_id) do
      :ok ->
        {:ok, %EctoLibSql.Result{}, state}

      {:error, _reason} ->
        # Cursor might already be deallocated, that's ok
        {:ok, %EctoLibSql.Result{}, state}
    end
  end

  @impl true
  @doc """
  Declares a cursor for streaming query results.

  Cursors allow you to iterate through large result sets in chunks, which is
  more memory-efficient than loading all rows at once.
  """
  def handle_declare(
        %EctoLibSql.Query{statement: statement} = query,
        params,
        _opts,
        %EctoLibSql.State{conn_id: conn_id, trx_id: trx_id} = state
      ) do
    # Use transaction ID if in a transaction, otherwise use connection ID
    id = trx_id || conn_id
    id_type = if trx_id, do: :transaction, else: :connection

    case EctoLibSql.Native.declare_cursor_with_context(conn_id, id, id_type, statement, params) do
      cursor_id when is_binary(cursor_id) ->
        cursor = %{ref: cursor_id}
        {:ok, query, cursor, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end
end
