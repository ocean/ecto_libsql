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
  def execute_with_transaction(_trx_id, _query, _args), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def query_with_trx_args(_trx_id, _query, _args), do: :erlang.nif_error(:nif_not_loaded)

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
  def declare_cursor_with_context(_id, _id_type, _sql, _args),
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
  def fetch_cursor(_cursor_id, _max_rows), do: :erlang.nif_error(:nif_not_loaded)

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
        %EctoLibSql.State{conn_id: _conn_id, trx_id: trx_id} = state,
        %EctoLibSql.Query{statement: statement} = query,
        args
      ) do
    # Check if statement has RETURNING clause - if so, use query instead of execute
    has_returning = String.contains?(String.upcase(statement), "RETURNING")

    if has_returning do
      # Use query_with_trx_args for statements with RETURNING
      case query_with_trx_args(trx_id, statement, args) do
        %{
          "columns" => columns,
          "rows" => rows,
          "num_rows" => num_rows
        } ->
          result = %EctoLibSql.Result{
            command: detect_command(statement),
            columns: columns,
            rows: rows,
            num_rows: num_rows
          }

          {:ok, query, result, state}

        {:error, message} ->
          {:error, %EctoLibSql.Error{message: message}, state}
      end
    else
      # Use execute for statements without RETURNING
      case execute_with_transaction(trx_id, statement, args) do
        num_rows when is_integer(num_rows) ->
          result = %EctoLibSql.Result{
            command: detect_command(statement),
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
end
