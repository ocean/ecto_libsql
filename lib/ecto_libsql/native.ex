defmodule EctoLibSql.Native do
  @moduledoc """
  Rust NIF (Native Implemented Functions) bridge for LibSQL operations.

  This module provides the low-level interface to the Rust-based LibSQL client,
  exposing both raw NIF functions and high-level Elixir helper functions.

  ## NIF Functions

  The NIF functions are implemented in Rust (`native/ecto_libsql/src/lib.rs`) and
  provide direct access to LibSQL operations:

  - Connection management: `connect/2`, `ping/1`, `close/2`
  - Query execution: `query_args/5`, `execute_with_transaction/3`
  - Transaction control: `begin_transaction_with_behavior/2`, `commit_or_rollback_transaction/5`
  - Prepared statements: `prepare_statement/2`, `query_prepared/5`, `execute_prepared/6`
  - Batch operations: `execute_batch/4`, `execute_transactional_batch/4`
  - Metadata: `last_insert_rowid/1`, `changes/1`, `total_changes/1`, `is_autocommit/1`
  - Cursors: `declare_cursor/3`, `fetch_cursor/2`
  - Sync: `do_sync/2`

  ## Helper Functions

  High-level Elixir wrappers that provide ergonomic interfaces:

  - `query/3`, `execute_non_trx/3`, `execute_with_trx/3` - Query execution
  - `begin/2`, `commit/1`, `rollback/1` - Transaction management
  - `prepare/2`, `execute_stmt/4`, `query_stmt/3`, `close_stmt/1` - Prepared statements
  - `batch/2`, `batch_transactional/2` - Batch operations
  - `get_last_insert_rowid/1`, `get_changes/1`, `get_total_changes/1`, `get_is_autocommit/1` - Metadata
  - `vector/1`, `vector_type/2`, `vector_distance_cos/2` - Vector search helpers
  - `sync/1` - Manual replica sync

  ## Thread Safety

  The Rust implementation uses thread-safe registries (using `Mutex<HashMap>`)
  to manage connections, transactions, statements, and cursors. Each is
  identified by a UUID for safe concurrent access.

  """

  use Rustler,
    otp_app: :ecto_libsql,
    crate: :ecto_libsql

  # Raw NIF functions - implemented in Rust (native/ecto_libsql/src/lib.rs)
  # These all raise :nif_not_loaded errors until the NIF is loaded

  @doc false
  def ping(_conn), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def connect(_opts, _mode), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def query_args(_conn, _mode, _query, _args, _sync), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def begin_transaction(_conn), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def begin_transaction_with_behavior(_conn, _behavior), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def execute_with_transaction(_trx_id, _conn_id, _query, _args),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def query_with_trx_args(_trx_id, _conn_id, _query, _args),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def handle_status_transaction(_trx_id), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def commit_or_rollback_transaction(_trx, _conn, _mode, _sync, _param),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def do_sync(_conn, _mode), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def close(_id, _opt), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def execute_batch(_conn, _mode, _sync, _statements), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def execute_transactional_batch(_conn, _mode, _sync, _statements),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def prepare_statement(_conn, _sql), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def query_prepared(_conn, _stmt_id, _mode, _sync, _args), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def execute_prepared(_conn, _stmt_id, _mode, _sync, _sql_hint, _args),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def declare_cursor_with_context(_conn_id, _id, _id_type, _sql, _args),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def last_insert_rowid(_conn), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def changes(_conn), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def total_changes(_conn), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def is_autocommit(_conn), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def declare_cursor(_conn, _sql, _args), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def fetch_cursor(_conn_id, _cursor_id, _max_rows), do: :erlang.nif_error(:nif_not_loaded)

  # Phase 1: Critical Production Features (v0.7.0)
  @doc false
  def set_busy_timeout(_conn_id, _timeout_ms), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def reset_connection(_conn_id), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def interrupt_connection(_conn_id), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def pragma_query(_conn_id, _pragma_stmt), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def execute_batch_native(_conn_id, _sql), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def execute_transactional_batch_native(_conn_id, _sql), do: :erlang.nif_error(:nif_not_loaded)

  # Phase 1: Statement Introspection & Savepoint Support (v0.7.0)
  @doc false
  def statement_column_count(_conn_id, _stmt_id), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def statement_column_name(_conn_id, _stmt_id, _idx), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def statement_parameter_count(_conn_id, _stmt_id), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def savepoint(_conn_id, _trx_id, _name), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def release_savepoint(_conn_id, _trx_id, _name), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def rollback_to_savepoint(_conn_id, _trx_id, _name), do: :erlang.nif_error(:nif_not_loaded)

  # Phase 2: Advanced Replica Features

  @doc false
  def get_frame_number(_conn_id), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def sync_until(_conn_id, _frame_no), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def flush_replicator(_conn_id), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def max_write_replication_index(_conn_id), do: :erlang.nif_error(:nif_not_loaded)

  # Internal NIF function - not supported, marked for deprecation
  # Always returns :unsupported atom rather than implementing the operation
  @doc false
  def freeze_database(_conn_id), do: :erlang.nif_error(:nif_not_loaded)

  # High-level Elixir helper functions

  @doc """
  Manually trigger a sync for embedded replicas.

  For connections in `:remote_replica` mode, this function forces a
  synchronisation with the remote Turso database, pulling down any changes
  from the remote and pushing local changes up.

  ## When to Use

  In most cases, you don't need to call this manually - automatic sync happens
  when you connect with `sync: true`. However, manual sync is useful for:

  - **Critical reads after remote writes**: When you need to immediately read
    data that was just written to the remote database
  - **Before shutdown**: Ensuring all local changes are synced before closing
    the connection
  - **After batch operations**: Forcing sync after bulk inserts/updates to
    ensure data is persisted remotely
  - **Coordinating between replicas**: When multiple replicas need to see
    consistent data immediately

  ## Parameters
    - state: The connection state (must be in `:remote_replica` mode)

  ## Returns
    - `{:ok, "success sync"}` on successful sync
    - `{:error, reason}` if sync fails

  ## Examples

      # Force sync after critical write
      {:ok, state} = EctoLibSql.connect(database: "local.db", uri: turso_uri, auth_token: token, sync: true)
      {:ok, _, _, state} = EctoLibSql.handle_execute("INSERT INTO users ...", [], [], state)
      {:ok, "success sync"} = EctoLibSql.Native.sync(state)

      # Ensure sync before shutdown
      {:ok, _} = EctoLibSql.Native.sync(state)
      :ok = EctoLibSql.disconnect([], state)

  ## Notes

  - Sync is only applicable for `:remote_replica` mode connections
  - For `:local` mode, this is a no-op
  - For `:remote` mode, data is already on the remote server
  - Sync happens synchronously and may take time depending on data size

  """
  def sync(%EctoLibSql.State{conn_id: conn_id, mode: mode} = _state) do
    do_sync(conn_id, mode)
  end

  @doc false
  def close_conn(id, opt, state) do
    case close(id, opt) do
      :ok -> :ok
      {:error, message} -> {:error, message, state}
    end
  end

  @doc false
  def execute_non_trx(query, state, args) do
    query(state, query, args)
  end

  @doc false
  def query(
        %EctoLibSql.State{conn_id: conn_id, mode: mode, sync: syncx} = state,
        %EctoLibSql.Query{statement: statement} = query,
        args
      ) do
    case query_args(conn_id, mode, syncx, statement, args) do
      %{
        "columns" => columns,
        "rows" => rows,
        "num_rows" => num_rows
      } ->
        command = detect_command(statement)

        # For INSERT/UPDATE/DELETE, get the actual affected row count from changes()
        # This is especially important for INSERT without RETURNING and batch operations
        actual_num_rows =
          if command in [:insert, :update, :delete] do
            case changes(conn_id) do
              n when is_integer(n) -> n
              _ -> num_rows
            end
          else
            num_rows
          end

        # For INSERT/UPDATE/DELETE without RETURNING, columns and rows will be empty
        # Set them to nil to match Ecto's expectations
        {columns, rows} =
          if command in [:insert, :update, :delete] and columns == [] and rows == [] do
            {nil, nil}
          else
            {columns, rows}
          end

        result = %EctoLibSql.Result{
          command: command,
          columns: columns,
          rows: rows,
          num_rows: actual_num_rows
        }

        {:ok, query, result, state}

      {:error, message} ->
        {:error, %EctoLibSql.Error{message: message}, state}
    end
  end

  @doc false
  def execute_with_trx(
        %EctoLibSql.State{conn_id: conn_id, trx_id: trx_id} = state,
        %EctoLibSql.Query{statement: statement} = query,
        args
      ) do
    # Detect the command type to route correctly
    command = detect_command(statement)

    # For SELECT statements (even without RETURNING), use query_with_trx_args
    # For INSERT/UPDATE/DELETE with RETURNING, use query_with_trx_args
    # For INSERT/UPDATE/DELETE without RETURNING, use execute_with_transaction
    # Use word-boundary regex to detect RETURNING precisely (matching Rust NIF behavior)
    has_returning = Regex.match?(~r/\bRETURNING\b/i, statement)
    should_query = command == :select or has_returning

    if should_query do
      # Use query_with_trx_args for SELECT or statements with RETURNING
      case query_with_trx_args(trx_id, conn_id, statement, args) do
        %{
          "columns" => columns,
          "rows" => rows,
          "num_rows" => num_rows
        } ->
          # For INSERT/UPDATE/DELETE without actual returned rows, normalize empty lists to nil
          # This ensures consistency with non-transactional path
          {columns, rows} =
            if command in [:insert, :update, :delete] and columns == [] and rows == [] do
              {nil, nil}
            else
              {columns, rows}
            end

          result = %EctoLibSql.Result{
            command: command,
            columns: columns,
            rows: rows,
            num_rows: num_rows
          }

          {:ok, query, result, state}

        {:error, message} ->
          {:error, %EctoLibSql.Error{message: message}, state}
      end
    else
      # Use execute_with_transaction for INSERT/UPDATE/DELETE without RETURNING
      case execute_with_transaction(trx_id, conn_id, statement, args) do
        num_rows when is_integer(num_rows) ->
          result = %EctoLibSql.Result{
            command: command,
            num_rows: num_rows
          }

          {:ok, query, result, state}

        {:error, message} ->
          {:error, %EctoLibSql.Error{message: message}, state}
      end
    end
  end

  @doc """
  Begin a new transaction with optional behaviour control.

  ## Parameters
    - state: The connection state
    - opts: Options keyword list
      - `:behavior` - Transaction behaviour (`:deferred`, `:immediate`, or `:exclusive`), defaults to `:deferred`

  ## Transaction Behaviours

  - `:deferred` - Default. Locks are acquired on first write operation
  - `:immediate` - Acquires write lock immediately when transaction begins
  - `:exclusive` - Acquires exclusive lock immediately, blocking all other connections

  ## Example
      {:ok, new_state} = EctoLibSql.Native.begin(state, behavior: :immediate)

  """
  def begin(%EctoLibSql.State{conn_id: conn_id, mode: mode} = _state, opts \\ []) do
    behavior = Keyword.get(opts, :behavior, :deferred)

    case begin_transaction_with_behavior(conn_id, behavior) do
      trx_id when is_binary(trx_id) ->
        {:ok, %EctoLibSql.State{conn_id: conn_id, trx_id: trx_id, mode: mode}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Commit the current transaction.

  For embedded replicas with auto-sync enabled, this also triggers a sync.

  ## Parameters
    - state: The connection state with an active transaction

  ## Example
      {:ok, _} = EctoLibSql.Native.commit(state)

  """
  def commit(
        %EctoLibSql.State{conn_id: conn_id, trx_id: trx_id, mode: mode, sync: syncx} = _state
      ) do
    commit_or_rollback_transaction(trx_id, conn_id, mode, syncx, "commit")
  end

  @doc """
  Roll back the current transaction.

  ## Parameters
    - state: The connection state with an active transaction

  ## Example
      {:ok, _} = EctoLibSql.Native.rollback(state)

  """
  def rollback(
        %EctoLibSql.State{conn_id: conn_id, trx_id: trx_id, mode: mode, sync: syncx} = _state
      ) do
    commit_or_rollback_transaction(trx_id, conn_id, mode, syncx, "rollback")
  end

  @doc false
  def detect_command(query) do
    query
    |> String.downcase()
    |> String.trim()
    |> String.split()
    |> List.first()
    |> case do
      "select" -> :select
      "insert" -> :insert
      "update" -> :update
      "delete" -> :delete
      "begin" -> :begin
      "commit" -> :commit
      "create" -> :create
      "rollback" -> :rollback
      _ -> :unknown
    end
  end

  @doc """
  Prepare a SQL statement for later execution. Returns a statement ID that can be reused.

  ## Parameters
    - state: The connection state
    - sql: The SQL query to prepare

  ## Example
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "SELECT * FROM users WHERE id = ?")
      {:ok, result} = EctoLibSql.Native.query_stmt(state, stmt_id, [42])
  """
  def prepare(%EctoLibSql.State{conn_id: conn_id} = _state, sql) do
    case prepare_statement(conn_id, sql) do
      stmt_id when is_binary(stmt_id) ->
        {:ok, stmt_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Execute a prepared statement with arguments (for non-SELECT queries).
  Returns the number of affected rows.

  ## Parameters
    - state: The connection state
    - stmt_id: The statement ID from prepare/2
    - sql: The original SQL (for sync detection)
    - args: List of parameters

  ## Example
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "INSERT INTO users (name) VALUES (?)")
      {:ok, rows_affected} = EctoLibSql.Native.execute_stmt(state, stmt_id, "INSERT INTO users (name) VALUES (?)", ["Alice"])
  """
  def execute_stmt(
        %EctoLibSql.State{conn_id: conn_id, mode: mode, sync: syncx} = _state,
        stmt_id,
        sql,
        args
      ) do
    case execute_prepared(conn_id, stmt_id, mode, syncx, sql, args) do
      num_rows when is_integer(num_rows) ->
        {:ok, num_rows}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Query using a prepared statement (for SELECT queries).
  Returns the result set.

  ## Parameters
    - state: The connection state
    - stmt_id: The statement ID from prepare/2
    - args: List of parameters

  ## Example
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "SELECT * FROM users WHERE id = ?")
      {:ok, result} = EctoLibSql.Native.query_stmt(state, stmt_id, [42])
  """
  def query_stmt(
        %EctoLibSql.State{conn_id: conn_id, mode: mode, sync: syncx} = _state,
        stmt_id,
        args
      ) do
    case query_prepared(conn_id, stmt_id, mode, syncx, args) do
      %{"columns" => columns, "rows" => rows, "num_rows" => num_rows} ->
        result = %EctoLibSql.Result{
          command: :select,
          columns: columns,
          rows: rows,
          num_rows: num_rows
        }

        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Close a prepared statement and free its resources.

  ## Parameters
    - stmt_id: The statement ID to close

  ## Example
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "SELECT * FROM users WHERE id = ?")
      # ... use statement ...
      :ok = EctoLibSql.Native.close_stmt(stmt_id)
  """
  def close_stmt(stmt_id) do
    close(stmt_id, :stmt_id)
  end

  @doc """
  Get the rowid of the last inserted row.

  ## Parameters
    - state: The connection state

  ## Example
      {:ok, _result, state} = EctoLibSql.Native.execute_non_trx(query, state, ["Alice"])
      rowid = EctoLibSql.Native.get_last_insert_rowid(state)
  """
  def get_last_insert_rowid(%EctoLibSql.State{conn_id: conn_id} = _state) do
    last_insert_rowid(conn_id)
  end

  @doc """
  Get the number of rows modified by the last INSERT, UPDATE or DELETE statement.

  ## Parameters
    - state: The connection state

  ## Example
      {:ok, _result, state} = EctoLibSql.Native.execute_non_trx(query, state, [])
      num_changes = EctoLibSql.Native.get_changes(state)
  """
  def get_changes(%EctoLibSql.State{conn_id: conn_id} = _state) do
    changes(conn_id)
  end

  @doc """
  Get the total number of rows modified, inserted or deleted since the database connection was opened.

  ## Parameters
    - state: The connection state

  ## Example
      total = EctoLibSql.Native.get_total_changes(state)
  """
  def get_total_changes(%EctoLibSql.State{conn_id: conn_id} = _state) do
    total_changes(conn_id)
  end

  @doc """
  Check if the connection is in autocommit mode (not in a transaction).

  ## Parameters
    - state: The connection state

  ## Example
      autocommit? = EctoLibSql.Native.get_is_autocommit(state)
  """
  def get_is_autocommit(%EctoLibSql.State{conn_id: conn_id} = _state) do
    is_autocommit(conn_id)
  end

  @doc """
  Create a vector from a list of numbers for use in vector columns.

  ## Parameters
    - values: List of numbers (integers or floats)

  ## Example
      # Create a 3-dimensional vector
      vec = EctoLibSql.Native.vector([1.0, 2.0, 3.0])
      # Use in query: "INSERT INTO items (embedding) VALUES (?)"
  """
  def vector(values) when is_list(values) do
    "[#{Enum.join(values, ",")}]"
  end

  @doc """
  Helper to create a vector column definition for CREATE TABLE.

  ## Parameters
    - dimensions: Number of dimensions
    - type: :f32 (float32) or :f64 (float64), defaults to :f32

  ## Example
      column_def = EctoLibSql.Native.vector_type(3)  # "F32_BLOB(3)"
      # Use in: "CREATE TABLE items (embedding \#{column_def})"
  """
  def vector_type(dimensions, type \\ :f32) when is_integer(dimensions) and dimensions > 0 do
    case type do
      :f32 -> "F32_BLOB(#{dimensions})"
      :f64 -> "F64_BLOB(#{dimensions})"
      _ -> raise ArgumentError, "type must be :f32 or :f64"
    end
  end

  @doc """
  Generate SQL for cosine distance vector similarity search.

  ## Parameters
    - column: Name of the vector column
    - vector: The query vector (list of numbers or vector string)

  ## Example
      distance_sql = EctoLibSql.Native.vector_distance_cos("embedding", [1.0, 2.0, 3.0])
      # Returns: "vector_distance_cos(embedding, '[1.0,2.0,3.0]')"
      # Use in: "SELECT * FROM items ORDER BY \#{distance_sql} LIMIT 10"
  """
  def vector_distance_cos(column, vector) when is_binary(column) do
    vec_str = if is_list(vector), do: vector(vector), else: vector
    "vector_distance_cos(#{column}, '#{vec_str}')"
  end

  @doc """
  Execute a batch of SQL statements. Each statement is executed independently.
  Returns a list of results for each statement.

  ## Parameters
    - state: The connection state
    - statements: A list of tuples {sql, args} where sql is the SQL string and args is a list of parameters

  ## Example
      statements = [
        {"INSERT INTO users (name) VALUES (?)", ["Alice"]},
        {"INSERT INTO users (name) VALUES (?)", ["Bob"]},
        {"SELECT * FROM users", []}
      ]
      {:ok, results} = EctoLibSql.Native.batch(state, statements)
  """
  def batch(%EctoLibSql.State{conn_id: conn_id, mode: mode, sync: syncx} = _state, statements) do
    case execute_batch(conn_id, mode, syncx, statements) do
      results when is_list(results) ->
        # Convert each result to EctoLibSql.Result struct
        parsed_results =
          Enum.map(results, fn result ->
            case result do
              %{"columns" => columns, "rows" => rows, "num_rows" => num_rows} ->
                %EctoLibSql.Result{
                  command: :batch,
                  columns: columns,
                  rows: rows,
                  num_rows: num_rows
                }

              _ ->
                %EctoLibSql.Result{command: :batch}
            end
          end)

        {:ok, parsed_results}

      {:error, message} ->
        {:error, message}
    end
  end

  @doc """
  Execute a batch of SQL statements in a transaction. All statements are executed
  atomically - if any statement fails, all changes are rolled back.

  ## Parameters
    - state: The connection state
    - statements: A list of tuples {sql, args} where sql is the SQL string and args is a list of parameters

  ## Example
      statements = [
        {"INSERT INTO users (name) VALUES (?)", ["Alice"]},
        {"INSERT INTO users (name) VALUES (?)", ["Bob"]},
        {"UPDATE users SET active = 1", []}
      ]
      {:ok, results} = EctoLibSql.Native.batch_transactional(state, statements)
  """
  def batch_transactional(
        %EctoLibSql.State{conn_id: conn_id, mode: mode, sync: syncx} = _state,
        statements
      ) do
    case execute_transactional_batch(conn_id, mode, syncx, statements) do
      results when is_list(results) ->
        # Convert each result to EctoLibSql.Result struct
        parsed_results =
          Enum.map(results, fn result ->
            case result do
              %{"columns" => columns, "rows" => rows, "num_rows" => num_rows} ->
                %EctoLibSql.Result{
                  command: :batch,
                  columns: columns,
                  rows: rows,
                  num_rows: num_rows
                }

              _ ->
                %EctoLibSql.Result{command: :batch}
            end
          end)

        {:ok, parsed_results}

      {:error, message} ->
        {:error, message}
    end
  end

  @doc """
  Set the busy timeout for the connection.

  This controls how long SQLite waits when a table is locked before returning
  a SQLITE_BUSY error. By default, SQLite returns immediately when encountering
  a lock. Setting a timeout allows for better concurrency handling.

  ## Parameters
    - state: The connection state
    - timeout_ms: Timeout in milliseconds (default: 5000)

  ## Example

      # Set 5 second timeout (recommended default)
      :ok = EctoLibSql.Native.busy_timeout(state, 5000)

      # Set 10 second timeout for write-heavy workloads
      :ok = EctoLibSql.Native.busy_timeout(state, 10_000)

  ## Notes

  - A value of 0 disables the busy handler (immediate SQLITE_BUSY on contention)
  - Recommended production default is 5000ms (5 seconds)
  - For write-heavy workloads, consider 10000ms or higher

  """
  def busy_timeout(%EctoLibSql.State{conn_id: conn_id} = _state, timeout_ms \\ 5000)
      when is_integer(timeout_ms) and timeout_ms >= 0 do
    set_busy_timeout(conn_id, timeout_ms)
  end

  @doc """
  Reset the connection to a clean state.

  This clears any cached state and resets the connection. Useful for:
  - Connection pooling (ensuring clean state when returning to pool)
  - Recovering from errors
  - Clearing any uncommitted transaction state

  ## Parameters
    - state: The connection state

  ## Example

      :ok = EctoLibSql.Native.reset(state)

  """
  def reset(%EctoLibSql.State{conn_id: conn_id} = _state) do
    reset_connection(conn_id)
  end

  @doc """
  Interrupt any ongoing operation on this connection.

  Causes the current database operation to abort and return at the earliest
  opportunity. Useful for:
  - Cancelling long-running queries
  - Implementing query timeouts
  - Graceful shutdown

  ## Parameters
    - state: The connection state

  ## Example

      # From another process, cancel a long query
      :ok = EctoLibSql.Native.interrupt(state)

  ## Notes

  - This is safe to call from any thread/process
  - The interrupted operation will return an error

  """
  def interrupt(%EctoLibSql.State{conn_id: conn_id} = _state) do
    interrupt_connection(conn_id)
  end

  @doc """
  Execute multiple SQL statements from a semicolon-separated string.

  Uses LibSQL's native batch execution for optimal performance. This is more
  efficient than executing statements one-by-one as it reduces round-trips
  and allows LibSQL to optimize the execution.

  Each statement is executed independently. If one fails, others may still
  complete.

  ## Parameters
    - state: The connection state
    - sql: Semicolon-separated SQL statements

  ## Example

      sql = \"""
      CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, name TEXT);
      INSERT INTO users (name) VALUES ('Alice');
      INSERT INTO users (name) VALUES ('Bob');
      SELECT * FROM users;
      \"""

      {:ok, results} = EctoLibSql.Native.execute_batch_sql(state, sql)

  ## Returns

  A list of results, one for each statement. Each result is either:
  - A map with columns/rows for SELECT statements
  - `nil` for statements that don't return data

  """
  def execute_batch_sql(%EctoLibSql.State{conn_id: conn_id} = _state, sql)
      when is_binary(sql) do
    case execute_batch_native(conn_id, sql) do
      results when is_list(results) ->
        {:ok, results}

      {:error, message} ->
        {:error, message}
    end
  end

  @doc """
  Execute multiple SQL statements atomically in a transaction.

  Uses LibSQL's native transactional batch execution. All statements execute
  within a single transaction - if any statement fails, all changes are
  rolled back.

  ## Parameters
    - state: The connection state
    - sql: Semicolon-separated SQL statements

  ## Example

      sql = \"""
      UPDATE accounts SET balance = balance - 100 WHERE id = 1;
      UPDATE accounts SET balance = balance + 100 WHERE id = 2;
      INSERT INTO transfers (from_id, to_id, amount) VALUES (1, 2, 100);
      \"""

      {:ok, results} = EctoLibSql.Native.execute_transactional_batch_sql(state, sql)

  ## Notes

  - All statements succeed or all are rolled back
  - More efficient than manual transaction with multiple queries
  - Ideal for migrations, data loading, and multi-statement operations

  """
  def execute_transactional_batch_sql(%EctoLibSql.State{conn_id: conn_id} = _state, sql)
      when is_binary(sql) do
    case execute_transactional_batch_native(conn_id, sql) do
      results when is_list(results) ->
        {:ok, results}

      {:error, message} ->
        {:error, message}
    end
  end

  # ============================================================================
  # Phase 1: Statement Introspection & Savepoint Support (v0.7.0)
  # ============================================================================

  @doc """
  Get the number of columns in a prepared statement's result set.

  Returns the column count for statements that return rows (SELECT).
  Returns 0 for statements that don't return rows (INSERT, UPDATE, DELETE).

  ## Parameters
    - state: The connection state
    - stmt_id: The statement ID returned from `prepare/2`

  ## Example

      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "SELECT id, name, email FROM users")
      {:ok, count} = EctoLibSql.Native.stmt_column_count(state, stmt_id)
      # count = 3

  """
  def stmt_column_count(%EctoLibSql.State{conn_id: conn_id} = _state, stmt_id)
      when is_binary(stmt_id) do
    case statement_column_count(conn_id, stmt_id) do
      count when is_integer(count) -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Get the name of a column in a prepared statement by its index.

  Index is 0-based. Returns an error if the index is out of bounds.

  ## Parameters
    - state: The connection state
    - stmt_id: The statement ID returned from `prepare/2`
    - idx: Column index (0-based)

  ## Example

      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "SELECT id, name FROM users")
      {:ok, name} = EctoLibSql.Native.stmt_column_name(state, stmt_id, 0)
      # name = "id"
      {:ok, name} = EctoLibSql.Native.stmt_column_name(state, stmt_id, 1)
      # name = "name"

  """
  def stmt_column_name(%EctoLibSql.State{conn_id: conn_id} = _state, stmt_id, idx)
      when is_binary(stmt_id) and is_integer(idx) and idx >= 0 do
    case statement_column_name(conn_id, stmt_id, idx) do
      name when is_binary(name) -> {:ok, name}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Get the number of parameters in a prepared statement.

  Parameters are the placeholders (?) in the SQL statement.

  ## Parameters
    - state: The connection state
    - stmt_id: The statement ID returned from `prepare/2`

  ## Example

      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "SELECT * FROM users WHERE id = ? AND name = ?")
      {:ok, count} = EctoLibSql.Native.stmt_parameter_count(state, stmt_id)
      # count = 2

  """
  def stmt_parameter_count(%EctoLibSql.State{conn_id: conn_id} = _state, stmt_id)
      when is_binary(stmt_id) do
    case statement_parameter_count(conn_id, stmt_id) do
      count when is_integer(count) -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Create a savepoint within a transaction.

  Savepoints allow partial rollback without aborting the entire transaction.
  They enable nested transaction-like behaviour.

  ## Parameters
    - state: The connection state with an active transaction
    - name: The savepoint name (must be unique within the transaction)

  ## Example

      {:ok, trx_state} = EctoLibSql.Native.begin(state)
      :ok = EctoLibSql.Native.create_savepoint(trx_state, "sp1")

      # Do some work...
      {:ok, _query, _result, trx_state} = EctoLibSql.Native.execute_with_trx(trx_state, "INSERT INTO users VALUES (?)", ["Alice"])

      # Create nested savepoint
      :ok = EctoLibSql.Native.create_savepoint(trx_state, "sp2")

  ## Notes

  - Savepoints must be created within an active transaction
  - Savepoint names must be valid SQL identifiers
  - You can create nested savepoints

  """
  def create_savepoint(%EctoLibSql.State{conn_id: conn_id, trx_id: trx_id} = _state, name)
      when is_binary(conn_id) and is_binary(trx_id) and is_binary(name) do
    case savepoint(conn_id, trx_id, name) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, "Unexpected response: #{inspect(other)}"}
    end
  end

  def create_savepoint(%EctoLibSql.State{trx_id: nil}, _name) do
    {:error, "No active transaction - cannot create savepoint outside transaction"}
  end

  @doc """
  Release (commit) a savepoint, making its changes permanent within the transaction.

  ## Parameters
    - state: The connection state with an active transaction
    - name: The savepoint name to release

  ## Example

      {:ok, trx_state} = EctoLibSql.Native.begin(state)
      :ok = EctoLibSql.Native.create_savepoint(trx_state, "sp1")
      # ... do work ...
      :ok = EctoLibSql.Native.release_savepoint_by_name(trx_state, "sp1")

  """
  def release_savepoint_by_name(
        %EctoLibSql.State{conn_id: conn_id, trx_id: trx_id} = _state,
        name
      )
      when is_binary(conn_id) and is_binary(trx_id) and is_binary(name) do
    case release_savepoint(conn_id, trx_id, name) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, "Unexpected response: #{inspect(other)}"}
    end
  end

  def release_savepoint_by_name(%EctoLibSql.State{trx_id: nil}, _name) do
    {:error, "No active transaction"}
  end

  @doc """
  Rollback to a savepoint, undoing all changes made after the savepoint was created.

  The savepoint remains active after rollback and can be released or rolled back to again.
  The transaction itself remains active.

  ## Parameters
    - state: The connection state with an active transaction
    - name: The savepoint name to rollback to

  ## Example

      {:ok, trx_state} = EctoLibSql.Native.begin(state)
      {:ok, _query, _result, trx_state} = EctoLibSql.Native.execute_with_trx(trx_state, "INSERT INTO users VALUES (?)", ["Alice"])

      :ok = EctoLibSql.Native.create_savepoint(trx_state, "sp1")
      {:ok, _query, _result, trx_state} = EctoLibSql.Native.execute_with_trx(trx_state, "INSERT INTO users VALUES (?)", ["Bob"])

      # Rollback Bob insert, keep Alice
      :ok = EctoLibSql.Native.rollback_to_savepoint_by_name(trx_state, "sp1")

      # Transaction still active, can continue or commit
      :ok = EctoLibSql.Native.commit(trx_state)

  """
  def rollback_to_savepoint_by_name(
        %EctoLibSql.State{conn_id: conn_id, trx_id: trx_id} = _state,
        name
      )
      when is_binary(conn_id) and is_binary(trx_id) and is_binary(name) do
    case rollback_to_savepoint(conn_id, trx_id, name) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, "Unexpected response: #{inspect(other)}"}
    end
  end

  def rollback_to_savepoint_by_name(%EctoLibSql.State{trx_id: nil}, _name) do
    {:error, "No active transaction"}
  end

  # Phase 2: Advanced Replica Features

  @doc """
  Get the current replication frame number from a remote replica.

  This returns the current frame number at the local replica, useful for monitoring
  replication progress. The frame number increases with each replication event.

  ## Parameters
    - conn_id: The connection ID (usually state.conn_id)

  ## Returns
    - `{:ok, frame_no}` - The current frame number (0 if not a replica)
    - `{:error, reason}` - If the connection is invalid

  ## Example

      {:ok, frame_no} = EctoLibSql.Native.get_frame_number_for_replica(state.conn_id)
      Logger.info("Current replication frame: " <> to_string(frame_no))

  ## Notes
    - Returns 0 if the database is not a remote replica
    - For local databases, this is not applicable
    - Useful for implementing replication lag monitoring

  """
  def get_frame_number_for_replica(conn_id) when is_binary(conn_id) do
    case get_frame_number(conn_id) do
      frame_no when is_integer(frame_no) -> {:ok, frame_no}
      {:error, reason} -> {:error, reason}
      other -> {:error, "Unexpected response: #{inspect(other)}"}
    end
  end

  def get_frame_number_for_replica(%EctoLibSql.State{conn_id: conn_id}) do
    get_frame_number_for_replica(conn_id)
  end

  @doc """
  Sync a remote replica until a specific frame number is reached.

  Waits for the replica to catch up to the specified frame number,
  which is useful after bulk writes to the primary database.

  ## Parameters
    - conn_id: The connection ID
    - target_frame: The target frame number to sync until

  ## Returns
    - `:ok` - Successfully synced to the target frame
    - `{:error, reason}` - If sync failed or connection is invalid

  ## Example

      # After bulk insert on primary, wait for replica to catch up
      primary_frame = get_primary_frame_number()
      :ok = EctoLibSql.Native.sync_until_frame(replica_conn_id, primary_frame)
      # Replica is now up-to-date

  ## Notes
    - This blocks until the frame is reached (with internal timeout)
    - Only works for remote replica connections
    - Returns error if called on local or remote primary connections

  """
  def sync_until_frame(conn_id, target_frame)
      when is_binary(conn_id) and is_integer(target_frame) do
    case sync_until(conn_id, target_frame) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, "Unexpected response: #{inspect(other)}"}
    end
  end

  def sync_until_frame(%EctoLibSql.State{conn_id: conn_id}, target_frame)
      when is_integer(target_frame) do
    sync_until_frame(conn_id, target_frame)
  end

  @doc """
  Flush the replicator, pushing pending writes to the remote database.

  This forces the local replica to synchronize with the remote database,
  sending any pending local changes.

  ## Parameters
    - conn_id: The connection ID

  ## Returns
    - `{:ok, new_frame}` - Flush succeeded, returns new frame number
    - `{:error, reason}` - If flush failed

  ## Example

      {:ok, frame} = EctoLibSql.Native.flush_and_get_frame(replica_conn_id)
      Logger.info("Flushed to frame: " <> to_string(frame))

  ## Notes
    - This is useful before taking snapshots or backups
    - Returns the frame number after the flush (0 if not a replica)
    - For local or remote primary connections, returns 0

  """
  def flush_and_get_frame(conn_id) when is_binary(conn_id) do
    case flush_replicator(conn_id) do
      frame_no when is_integer(frame_no) -> {:ok, frame_no}
      {:error, reason} -> {:error, reason}
      other -> {:error, "Unexpected response: #{inspect(other)}"}
    end
  end

  def flush_and_get_frame(%EctoLibSql.State{conn_id: conn_id}) do
    flush_and_get_frame(conn_id)
  end

  @doc """
  Get the highest frame number from write operations on this database.

  This is useful for read-your-writes consistency across replicas. After
  performing writes on one connection (typically a primary or another replica),
  you can use this function to get the maximum write frame, then use
  `sync_until_frame/2` on other replicas to ensure they've synced up to at
  least that frame before reading.

  ## Parameters
    - conn_id: The connection ID

  ## Returns
    - `{:ok, frame_no}` - The highest frame number from write operations (0 if no writes tracked)
    - `{:error, reason}` - If the connection is invalid

  ## Example

      # On primary/writer connection, after writes
      {:ok, max_write_frame} = EctoLibSql.Native.get_max_write_frame(primary_conn_id)

      # On replica connection, ensure it's synced to at least that frame
      :ok = EctoLibSql.Native.sync_until_frame(replica_conn_id, max_write_frame)

      # Now safe to read from replica - guaranteed to see writes from primary

  ## Notes
    - Returns 0 if the database doesn't track write replication index
    - Different from `get_frame_number_for_replica/1` which returns current replication position
    - This tracks the highest frame number from YOUR write operations
    - Essential for read-your-writes consistency in multi-replica setups

  """
  def get_max_write_frame(conn_id) when is_binary(conn_id) do
    case max_write_replication_index(conn_id) do
      frame_no when is_integer(frame_no) -> {:ok, frame_no}
      {:error, reason} -> {:error, reason}
      other -> {:error, "Unexpected response: #{inspect(other)}"}
    end
  end

  def get_max_write_frame(%EctoLibSql.State{conn_id: conn_id}) do
    get_max_write_frame(conn_id)
  end

  @doc """
  Freeze a remote replica, converting it to a standalone local database.

  ⚠️ **NOT SUPPORTED** - This function is currently not implemented.

  Freeze is intended to convert a remote replica to a standalone local database
  for disaster recovery. However, this operation requires deep refactoring of the
  connection pool architecture and remains unimplemented. Instead, you can:

  - **Option 1**: Backup the replica database file and use it independently
  - **Option 2**: Replicate all data to a new local database
  - **Option 3**: Keep the replica and manage failover at the application level

  Always returns `{:error, :unsupported}`.

  ## Parameters
    - state: The connection state

  ## Returns
    - `{:error, :unsupported}` - Always (not implemented)

  ## Example

      case EctoLibSql.Native.freeze_replica(replica_state) do
        {:ok, _frozen_state} ->
          # This will never succeed
          :unreachable

        {:error, :unsupported} ->
          Logger.error("Freeze is not supported. Use manual backup strategy instead.")
          {:error, :unsupported}
      end

  ## Implementation Status

  - **Blocker**: Requires taking ownership of the `Database` instance, which is
    held in `Arc<Mutex<LibSQLConn>>` within connection pool state
  - **Work Required**: Refactoring connection pool architecture to support
    consuming connections
  - **Timeline**: Uncertain - marked for future refactoring

  See CLAUDE.md for technical details on why this is not currently supported.

  """
  def freeze_replica(%EctoLibSql.State{conn_id: conn_id} = _state) when is_binary(conn_id) do
    # Always return unsupported - this feature is not implemented
    {:error, :unsupported}
  end

  def freeze_replica(_state) do
    {:error, :unsupported}
  end
end
