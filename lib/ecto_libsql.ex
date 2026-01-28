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
  @spec connect(Keyword.t()) :: {:ok, EctoLibSql.State.t()} | {:error, term()}
  def connect(opts) do
    mode = EctoLibSql.State.detect_mode(opts)

    case EctoLibSql.Native.connect(opts, mode) do
      conn_id when is_binary(conn_id) ->
        state = %EctoLibSql.State{
          conn_id: conn_id,
          mode: mode,
          sync: EctoLibSql.State.detect_sync(opts)
        }

        # Set busy_timeout for better concurrency handling
        busy_timeout = Keyword.get(opts, :busy_timeout, @default_busy_timeout)

        case EctoLibSql.Native.set_busy_timeout(conn_id, busy_timeout) do
          :ok ->
            {:ok, state}

          {:error, reason} ->
            # Log warning but don't fail connection - busy_timeout is an optimisation
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
  @spec ping(EctoLibSql.State.t()) ::
          {:ok, EctoLibSql.State.t()} | {:disconnect, :ping_failed, EctoLibSql.State.t()}
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
  @spec disconnect(term(), EctoLibSql.State.t()) ::
          :ok | {:error, term(), EctoLibSql.State.t()}
  def disconnect(_opts, %EctoLibSql.State{conn_id: conn_id} = state) do
    EctoLibSql.Native.close_conn(conn_id, :conn_id, state)
  end

  @impl true
  @doc """
  Executes an SQL query, delegating to transactional or non-transactional logic
  depending on the connection state.
  """
  @spec handle_execute(
          EctoLibSql.Query.t() | String.t(),
          list(),
          Keyword.t(),
          EctoLibSql.State.t()
        ) ::
          {:ok, EctoLibSql.Query.t(), EctoLibSql.Result.t(), EctoLibSql.State.t()}
          | {:error, EctoLibSql.Error.t(), EctoLibSql.State.t()}
  def handle_execute(query, args, _opts, %EctoLibSql.State{trx_id: trx_id} = state) do
    query_struct =
      case query do
        %EctoLibSql.Query{} -> query
        query when is_binary(query) -> %EctoLibSql.Query{statement: query}
      end

    # Check if query returns rows (SELECT, EXPLAIN, WITH, RETURNING clauses).
    # If so, route through query path instead of execute path.
    sql = query_struct.statement

    case EctoLibSql.Native.should_use_query_path(sql) do
      true ->
        # Query returns rows, use the query path.
        # Convert map arguments to list if needed (NIFs expect lists).
        normalised_args = normalise_args_for_query(sql, args)

        if trx_id do
          EctoLibSql.Native.query_with_trx_args(trx_id, state.conn_id, sql, normalised_args)
          |> format_query_result(state)
        else
          EctoLibSql.Native.query_args(
            state.conn_id,
            state.mode,
            state.sync,
            sql,
            normalised_args
          )
          |> format_query_result(state)
        end

      false ->
        # Query doesn't return rows, use the execute path (INSERT/UPDATE/DELETE).
        # Note: execute_with_trx and execute_non_trx handle argument normalisation internally.
        if trx_id do
          EctoLibSql.Native.execute_with_trx(state, query_struct, args)
        else
          EctoLibSql.Native.execute_non_trx(query_struct, state, args)
        end
    end
  end

  # Helper to format raw query results for return
  defp format_query_result(%{"columns" => columns, "rows" => rows, "num_rows" => num_rows}, state) do
    result = %EctoLibSql.Result{
      columns: columns,
      rows: rows,
      num_rows: num_rows
    }

    {:ok, %EctoLibSql.Query{}, result, state}
  end

  defp format_query_result({:error, reason}, state) do
    error = build_error(reason)
    {:error, error, state}
  end

  # Build an EctoLibSql.Error from various reason formats.
  defp build_error(%EctoLibSql.Error{} = error), do: error

  defp build_error(reason) when is_binary(reason) do
    %EctoLibSql.Error{message: reason, sqlite: %{code: :error, message: reason}}
  end

  defp build_error(reason) when is_map(reason) do
    message = Map.get(reason, :message) || Map.get(reason, "message") || inspect(reason)
    %EctoLibSql.Error{message: message, sqlite: %{code: :error, message: message}}
  end

  defp build_error(reason) do
    message = inspect(reason)
    %EctoLibSql.Error{message: message, sqlite: %{code: :error, message: message}}
  end

  # Convert map arguments to a list by extracting named parameters from SQL.
  # If args is already a list, return it unchanged.
  defp normalise_args_for_query(_sql, args) when is_list(args), do: args

  defp normalise_args_for_query(sql, args) when is_map(args) do
    # Extract named parameters from SQL in order of appearance.
    # Supports :name, $name, and @name formats.
    param_names = extract_named_params(sql)

    # Validate that all parameters exist in the map and collect missing ones.
    missing_params =
      Enum.filter(param_names, fn name ->
        not has_param?(args, name)
      end)

    # Raise error if any parameters are missing.
    if missing_params != [] do
      missing_list = Enum.map_join(missing_params, ", ", &":#{&1}")

      raise ArgumentError,
            "Missing required parameters: #{missing_list}. " <>
              "SQL requires: #{Enum.map_join(param_names, ", ", &":#{&1}")}"
    end

    # Convert map values to list in parameter order.
    Enum.map(param_names, fn name ->
      get_param_value(args, name)
    end)
  end

  # Check if a parameter exists in the map (supports both atom and string keys).
  # Uses String.to_existing_atom/1 to avoid atom table exhaustion from dynamic SQL.
  defp has_param?(map, name) when is_binary(name) do
    # Try existing atom key first (common case), then string key.
    try do
      atom_key = String.to_existing_atom(name)
      Map.has_key?(map, atom_key) or Map.has_key?(map, name)
    rescue
      ArgumentError ->
        # Atom doesn't exist, check string key only.
        Map.has_key?(map, name)
    end
  end

  # Get a parameter value from a map, supporting both atom and string keys.
  # Uses String.to_existing_atom/1 to avoid atom table exhaustion from dynamic SQL.
  # This assumes the parameter exists (validated by has_param?).
  defp get_param_value(map, name) when is_binary(name) do
    # Try existing atom key first (common case), then string key.
    atom_key = String.to_existing_atom(name)
    Map.get(map, atom_key, Map.get(map, name))
  rescue
    ArgumentError ->
      # Atom doesn't exist, try string key only.
      Map.get(map, name)
  end

  # Extract named parameter names from SQL in order of appearance.
  # Returns a list of strings to avoid atom table exhaustion from dynamic SQL.
  #
  # LIMITATION: This regex-based approach cannot distinguish between parameter-like
  # patterns in SQL string literals or comments and actual parameters. For example:
  #
  #   SELECT ':not_a_param', name FROM users WHERE id = :actual_param
  #
  # Would extract both "not_a_param" and "actual_param", even though the first
  # appears in a string literal. This is an edge case that would require a full
  # SQL parser to handle correctly (tracking quoted strings, escaped characters,
  # and comment blocks). In practice, this limitation rarely causes issues because:
  # 1. SQL string literals containing parameter-like patterns are uncommon
  # 2. The validation will catch truly missing parameters
  # 3. Extra entries in the parameter list are ignored during binding
  #
  # If this becomes problematic, consider using a proper SQL parser or the
  # prepared statement introspection approach used in lib/ecto_libsql/native.ex.
  defp extract_named_params(sql) do
    # Match :name, $name, or @name patterns.
    ~r/[:$@]([a-zA-Z_][a-zA-Z0-9_]*)/
    |> Regex.scan(sql)
    |> Enum.map(fn [_full, name] -> name end)
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

        if rows == [] do
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
