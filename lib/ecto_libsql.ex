defmodule EctoLibSql do
  @moduledoc """
  Ecto adapter for LibSQL databases.

  This module implements the `DBConnection` behavior to provide a complete database
  adapter for LibSQL, supporting both local SQLite files and remote Turso databases.

  ## Features

    * **Multiple Connection Modes**
      * Local - Direct connection to SQLite database files
      * Remote - Connection to remote LibSQL/Turso servers
      * Remote Replica - Local database with remote synchronization

    * **Full Transaction Support**
      * Standard transactions (BEGIN, COMMIT, ROLLBACK)
      * Transaction behaviors (deferred, immediate, exclusive)
      * Automatic transaction state tracking

    * **Advanced Query Features**
      * Parameterized queries for SQL injection prevention
      * Prepared statements for performance
      * Batch operations (transactional and non-transactional)
      * Cursor support for streaming large result sets

    * **Vector Operations**
      * Vector similarity search support
      * Cosine distance calculations
      * Optimized for embeddings and AI applications

    * **Production Ready**
      * Connection pooling via DBConnection
      * Comprehensive error handling
      * Health checks and connection validation

  ## Configuration

  Add to your config/config.exs:

      config :my_app, MyApp.Repo,
        database: "path/to/database.db"

  For remote Turso connections:

      config :my_app, MyApp.Repo,
        uri: "libsql://your-database.turso.io",
        auth_token: "your-auth-token"

  For remote replica (embedded replica):

      config :my_app, MyApp.Repo,
        database: "local.db",
        uri: "libsql://your-database.turso.io",
        auth_token: "your-auth-token",
        sync: true

  ## Usage with Ecto

  Define your repo:

      defmodule MyApp.Repo do
        use Ecto.Repo,
          otp_app: :my_app,
          adapter: EctoLibSql
      end

  ## Direct DBConnection Usage

  For lower-level access without Ecto:

      {:ok, conn} = DBConnection.start_link(EctoLibSql, database: "test.db")
      {:ok, query, result, _conn} = DBConnection.execute(conn, %EctoLibSql.Query{statement: "SELECT 1"}, [])

  ## Limitations

  This adapter does not currently support:
    * `handle_fetch/4` - Partial cursor support (implemented but not fully featured)
    * `handle_declare/4` - Cursor declaration (implemented)
    * `handle_deallocate/4` - Resource deallocation (implemented)

  See `EctoLibSql.Native` for direct access to prepared statements, batch operations,
  and vector features.

  """

  use DBConnection

  @impl true
  @doc """
  Establishes a connection to the LibSQL database.

  This callback opens a new database connection using the provided options.
  The connection mode (local, remote, or remote replica) is automatically
  detected based on the options provided.

  ## Options

    * `:database` - Path to local SQLite database file
    * `:uri` - Remote LibSQL/Turso server URI (e.g., "libsql://db.turso.io")
    * `:auth_token` - Authentication token for remote connections
    * `:sync` - Enable automatic synchronization for remote replicas (boolean)

  ## Connection Modes

  The adapter automatically selects the appropriate mode:

    * **Local** - Only `:database` provided
    * **Remote** - `:uri` and `:auth_token` provided
    * **Remote Replica** - All four options provided (`:database`, `:uri`, `:auth_token`, `:sync`)

  ## Returns

    * `{:ok, state}` - Success with connection state
    * `{:error, reason}` - Failure with error description

  ## Examples

      # Local database
      EctoLibSql.connect(database: "local.db")

      # Remote Turso database
      EctoLibSql.connect(uri: "libsql://db.turso.io", auth_token: "token")

      # Remote replica
      EctoLibSql.connect(
        database: "local.db",
        uri: "libsql://db.turso.io",
        auth_token: "token",
        sync: true
      )

  """
  def connect(opts) do
    case EctoLibSql.Native.connect(opts, EctoLibSql.State.detect_mode(opts)) do
      conn_id when is_binary(conn_id) ->
        {:ok,
         %EctoLibSql.State{
           conn_id: conn_id,
           mode: EctoLibSql.State.detect_mode(opts),
           sync: EctoLibSql.State.detect_sync(opts)
         }}

      {:error, _} = err ->
        err

      other ->
        {:error, {:unexpected_response, other}}
    end
  end

  @impl true
  @doc """
  Pings the connection to verify it is still alive.

  This callback is used by the connection pool to perform health checks
  and detect dead connections.

  ## Parameters

    * `state` - Current connection state

  ## Returns

    * `{:ok, state}` - Connection is alive
    * `{:disconnect, :ping_failed, state}` - Connection is dead

  """
  def ping(%EctoLibSql.State{conn_id: conn_id} = state) do
    case EctoLibSql.Native.ping(conn_id) do
      true -> {:ok, state}
      _ -> {:disconnect, :ping_failed, state}
    end
  end

  @impl true
  @doc """
  Closes the database connection.

  This callback is called when the connection process is terminating.
  It ensures all resources are properly cleaned up.

  ## Parameters

    * `_opts` - Disconnect options (unused)
    * `state` - Current connection state

  ## Returns

    * `:ok` on success
    * `{:error, message, state}` on failure

  """
  def disconnect(_opts, %EctoLibSql.State{conn_id: conn_id, trx_id: _trx_id} = state) do
    EctoLibSql.Native.close_conn(conn_id, :conn_id, state)
  end

  @impl true
  @doc """
  Executes a SQL query.

  This callback handles query execution, automatically choosing between
  transactional and non-transactional execution based on the connection state.

  ## Parameters

    * `query` - Either a `EctoLibSql.Query` struct or a SQL string
    * `args` - List of parameters for the query
    * `_opts` - Execution options (unused)
    * `state` - Current connection state

  ## Returns

    * `{:ok, query, result, state}` - Success with query result
    * `{:error, query, exception, state}` - Failure with error details

  ## Behavior

  If `state.trx_id` is present, the query executes within the active transaction.
  Otherwise, it executes as a standalone statement.

  ## Examples

      # Simple query
      EctoLibSql.handle_execute("SELECT * FROM users", [], [], state)

      # Parameterized query
      query = %EctoLibSql.Query{statement: "SELECT * FROM users WHERE id = ?"}
      EctoLibSql.handle_execute(query, [42], [], state)

      # Within a transaction
      {:ok, :begin, state} = EctoLibSql.handle_begin([], state)
      EctoLibSql.handle_execute(query, [42], [], state)

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

  This callback starts a transaction and updates the connection state
  to track the transaction ID.

  ## Parameters

    * `opts` - Transaction options
      * `:behavior` - Transaction behavior (`:deferred`, `:immediate`, `:exclusive`)
    * `state` - Current connection state

  ## Transaction Behaviors

    * `:deferred` (default) - Lock acquired when first statement executes
    * `:immediate` - Reserved lock acquired immediately
    * `:exclusive` - Exclusive lock acquired immediately

  ## Returns

    * `{:ok, :begin, new_state}` - Success with transaction ID in state
    * `{:error, reason, state}` - Failure with error reason

  ## Example

      {:ok, :begin, state} = EctoLibSql.handle_begin([behavior: :immediate], state)

  """
  def handle_begin(opts, state) do
    case EctoLibSql.Native.begin(state, opts) do
      {:ok, new_state} -> {:ok, :begin, new_state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  @impl true
  @doc false
  def handle_commit(_opts, %EctoLibSql.State{trx_id: nil} = state) do
    {:error, %RuntimeError{message: "no active transaction"}, state}
  end

  @impl true
  @doc """
  Commits the current transaction.

  This callback commits all changes made within the transaction and
  clears the transaction ID from the connection state.

  ## Parameters

    * `_opts` - Commit options (unused)
    * `state` - Current connection state (must have active transaction)

  ## Returns

    * `{:ok, result, new_state}` - Success with cleared transaction state
    * `{:disconnect, reason, state}` - Failure requiring disconnection

  ## Example

      {:ok, :begin, state} = EctoLibSql.handle_begin([], state)
      # ... execute queries ...
      {:ok, result, state} = EctoLibSql.handle_commit([], state)

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

  This callback aborts the transaction and discards all changes made
  within it. The transaction ID is cleared from the connection state.

  ## Parameters

    * `_opts` - Rollback options (unused)
    * `state` - Current connection state (must have active transaction)

  ## Returns

    * `{:ok, result, new_state}` - Success with cleared transaction state
    * `{:disconnect, reason, state}` - Failure requiring disconnection

  ## Example

      {:ok, :begin, state} = EctoLibSql.handle_begin([], state)
      # ... execute queries ...
      {:ok, result, state} = EctoLibSql.handle_rollback([], state)

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
  Closes a query.

  This is currently a no-op as query cleanup is handled automatically.

  ## Parameters

    * `_query` - Query to close
    * `_opts` - Close options
    * `state` - Current connection state

  ## Returns

    * `{:ok, result, state}` - Always succeeds with empty result

  """
  def handle_close(_query, _opts, state) do
    {:ok, %EctoLibSql.Result{}, state}
  end

  @impl true
  @doc """
  Checks the transaction status of the connection.

  This callback determines whether the connection is currently in a transaction.

  ## Parameters

    * `_opts` - Status options (unused)
    * `state` - Current connection state

  ## Returns

    * `{:transaction, state}` - Connection is in a transaction
    * `{:idle, state}` - Connection is not in a transaction
    * `{:disconnect, message, state}` - Transaction is in invalid state

  """
  def handle_status(_opts, %EctoLibSql.State{conn_id: _conn_id, trx_id: trx_id} = state) do
    case EctoLibSql.Native.handle_status_transaction(trx_id) do
      :ok -> {:transaction, state}
      {:error, message} -> {:disconnect, message, state}
    end
  end

  @impl true
  @doc """
  Prepares a query for execution.

  This is a pass-through implementation as query preparation is handled
  by the native layer during execution.

  ## Parameters

    * `query` - Query struct to prepare
    * `_opts` - Preparation options (unused)
    * `state` - Current connection state

  ## Returns

    * `{:ok, query, state}` - Always succeeds, returning the query unchanged

  """
  def handle_prepare(%EctoLibSql.Query{} = query, _opts, state) do
    {:ok, query, state}
  end

  @impl true
  @doc """
  Checks out a connection from the pool.

  This callback validates the connection is still alive before checkout.

  ## Parameters

    * `state` - Current connection state

  ## Returns

    * `{:ok, state}` - Connection is healthy
    * `{:disconnect, reason, state}` - Connection is dead

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

  This callback retrieves rows from an active cursor, supporting streaming
  of large result sets.

  ## Parameters

    * `_query` - Query associated with the cursor
    * `cursor` - Cursor reference with `:ref` field
    * `opts` - Fetch options
      * `:max_rows` - Maximum rows to fetch (default: 500)
    * `state` - Current connection state

  ## Returns

    * `{:cont, result, state}` - More rows available
    * `{:deallocated, result, state}` - No more rows, cursor closed
    * `{:error, reason, state}` - Fetch failed

  """
  def handle_fetch(%EctoLibSql.Query{} = _query, cursor, opts, %EctoLibSql.State{} = state) do
    max_rows = Keyword.get(opts, :max_rows, 500)

    case EctoLibSql.Native.fetch_cursor(cursor.ref, max_rows) do
      {columns, rows, _count} when is_list(rows) ->
        result = %EctoLibSql.Result{
          command: :select,
          columns: columns,
          rows: rows,
          num_rows: length(rows)
        }

        if length(rows) == 0 do
          # No more rows, deallocate cursor
          :ok = EctoLibSql.Native.close(cursor.ref, :cursor_id)
          {:deallocated, result, state}
        else
          {:cont, result, state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @impl true
  @doc """
  Deallocates a cursor.

  This callback explicitly closes a cursor and frees its resources.

  ## Parameters

    * `_query` - Query associated with the cursor
    * `cursor` - Cursor reference to deallocate
    * `_opts` - Deallocation options (unused)
    * `state` - Current connection state

  ## Returns

    * `{:ok, result, state}` - Cursor deallocated (or already closed)

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

  This callback creates a cursor that can be used to fetch large result sets
  in batches, avoiding loading all rows into memory at once.

  ## Parameters

    * `query` - Query struct with SQL statement
    * `params` - Query parameters
    * `_opts` - Declaration options (unused)
    * `state` - Current connection state

  ## Returns

    * `{:ok, query, cursor, state}` - Success with cursor reference
    * `{:error, reason, state}` - Cursor creation failed

  ## Example

      query = %EctoLibSql.Query{statement: "SELECT * FROM large_table"}
      {:ok, query, cursor, state} = EctoLibSql.handle_declare(query, [], [], state)
      {:cont, result, state} = EctoLibSql.handle_fetch(query, cursor, [max_rows: 100], state)

  """
  def handle_declare(
        %EctoLibSql.Query{statement: statement} = query,
        params,
        _opts,
        %EctoLibSql.State{conn_id: conn_id} = state
      ) do
    case EctoLibSql.Native.declare_cursor(conn_id, statement, params) do
      cursor_id when is_binary(cursor_id) ->
        cursor = %{ref: cursor_id}
        {:ok, query, cursor, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end
end
