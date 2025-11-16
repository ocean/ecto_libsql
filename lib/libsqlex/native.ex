defmodule LibSqlEx.Native do
  use Rustler,
    otp_app: :libsqlex,
    crate: :libsqlex

  # native bridge from rust check lib.rs
  def ping(_conn), do: :erlang.nif_error(:nif_not_loaded)
  def connect(_opts, _mode), do: :erlang.nif_error(:nif_not_loaded)
  def query_args(_conn, _mode, _query, _args, _sync), do: :erlang.nif_error(:nif_not_loaded)
  def begin_transaction(_conn), do: :erlang.nif_error(:nif_not_loaded)
  def begin_transaction_with_behavior(_conn, _behavior), do: :erlang.nif_error(:nif_not_loaded)
  def execute_with_transaction(_trx_id, _query, _args), do: :erlang.nif_error(:nif_not_loaded)
  def handle_status_transaction(_trx_id), do: :erlang.nif_error(:nif_not_loaded)

  def commit_or_rollback_transaction(_trx, _conn, _mode, _sync, _param),
    do: :erlang.nif_error(:nif_not_loaded)

  def do_sync(_conn, _mode), do: :erlang.nif_error(:nif_not_loaded)
  def close(_id, _opt), do: :erlang.nif_error(:nif_not_loaded)
  def execute_batch(_conn, _mode, _sync, _statements), do: :erlang.nif_error(:nif_not_loaded)

  def execute_transactional_batch(_conn, _mode, _sync, _statements),
    do: :erlang.nif_error(:nif_not_loaded)

  def prepare_statement(_conn, _sql), do: :erlang.nif_error(:nif_not_loaded)
  def query_prepared(_conn, _stmt_id, _mode, _sync, _args), do: :erlang.nif_error(:nif_not_loaded)

  def execute_prepared(_conn, _stmt_id, _mode, _sync, _args, _sql_hint),
    do: :erlang.nif_error(:nif_not_loaded)

  def last_insert_rowid(_conn), do: :erlang.nif_error(:nif_not_loaded)
  def changes(_conn), do: :erlang.nif_error(:nif_not_loaded)
  def total_changes(_conn), do: :erlang.nif_error(:nif_not_loaded)
  def is_autocommit(_conn), do: :erlang.nif_error(:nif_not_loaded)
  def declare_cursor(_conn, _sql, _args), do: :erlang.nif_error(:nif_not_loaded)
  def fetch_cursor(_cursor_id, _max_rows), do: :erlang.nif_error(:nif_not_loaded)

  # helper

  def sync(%LibSqlEx.State{conn_id: conn_id, mode: mode} = _state) do
    do_sync(conn_id, mode)
  end

  def close_conn(id, opt, state) do
    case close(id, opt) do
      :ok -> :ok
      {:error, message} -> {:error, message, state}
    end
  end

  def execute_non_trx(query, state, args) do
    query(state, query, args)
  end

  def query(
        %LibSqlEx.State{conn_id: conn_id, mode: mode, sync: syncx} = state,
        %LibSqlEx.Query{statement: statement} = query,
        args
      ) do
    case query_args(conn_id, mode, syncx, statement, args) do
      %{
        "columns" => columns,
        "rows" => rows,
        "num_rows" => num_rows
      } ->
        result = %LibSqlEx.Result{
          command: detect_command(statement),
          columns: columns,
          rows: rows,
          num_rows: num_rows
        }

        {:ok, query, result, state}

      {:error, message} ->
        {:error, query, message, state}
    end
  end

  def execute_with_trx(
        %LibSqlEx.State{conn_id: _conn_id, trx_id: trx_id} = state,
        %LibSqlEx.Query{statement: statement} = query,
        args
      ) do
    # nif NifResult<u64>
    case execute_with_transaction(trx_id, statement, args) do
      num_rows when is_integer(num_rows) ->
        result = %LibSqlEx.Result{
          command: detect_command(statement),
          num_rows: num_rows
        }

        {:ok, query, result, state}

      {:error, message} ->
        {:error, query, message, state}
    end
  end

  def begin(%LibSqlEx.State{conn_id: conn_id, mode: mode} = _state, opts \\ []) do
    behavior = Keyword.get(opts, :behavior, :deferred)

    case begin_transaction_with_behavior(conn_id, behavior) do
      trx_id when is_binary(trx_id) ->
        {:ok, %LibSqlEx.State{conn_id: conn_id, trx_id: trx_id, mode: mode}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def commit(%LibSqlEx.State{conn_id: conn_id, trx_id: trx_id, mode: mode, sync: syncx} = _state) do
    commit_or_rollback_transaction(trx_id, conn_id, mode, syncx, "commit")
  end

  def rollback(
        %LibSqlEx.State{conn_id: conn_id, trx_id: trx_id, mode: mode, sync: syncx} = _state
      ) do
    commit_or_rollback_transaction(trx_id, conn_id, mode, syncx, "rollback")
  end

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
      {:ok, stmt_id} = LibSqlEx.Native.prepare(state, "SELECT * FROM users WHERE id = ?")
      {:ok, result} = LibSqlEx.Native.query_stmt(state, stmt_id, [42])
  """
  def prepare(%LibSqlEx.State{conn_id: conn_id} = _state, sql) do
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
      {:ok, stmt_id} = LibSqlEx.Native.prepare(state, "INSERT INTO users (name) VALUES (?)")
      {:ok, rows_affected} = LibSqlEx.Native.execute_stmt(state, stmt_id, "INSERT INTO users (name) VALUES (?)", ["Alice"])
  """
  def execute_stmt(
        %LibSqlEx.State{conn_id: conn_id, mode: mode, sync: syncx} = _state,
        stmt_id,
        sql,
        args
      ) do
    case execute_prepared(conn_id, stmt_id, mode, syncx, args, sql) do
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
      {:ok, stmt_id} = LibSqlEx.Native.prepare(state, "SELECT * FROM users WHERE id = ?")
      {:ok, result} = LibSqlEx.Native.query_stmt(state, stmt_id, [42])
  """
  def query_stmt(
        %LibSqlEx.State{conn_id: conn_id, mode: mode, sync: syncx} = _state,
        stmt_id,
        args
      ) do
    case query_prepared(conn_id, stmt_id, mode, syncx, args) do
      %{"columns" => columns, "rows" => rows, "num_rows" => num_rows} ->
        result = %LibSqlEx.Result{
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
      {:ok, stmt_id} = LibSqlEx.Native.prepare(state, "SELECT * FROM users WHERE id = ?")
      # ... use statement ...
      :ok = LibSqlEx.Native.close_stmt(stmt_id)
  """
  def close_stmt(stmt_id) do
    close(stmt_id, :stmt_id)
  end

  @doc """
  Get the rowid of the last inserted row.

  ## Parameters
    - state: The connection state

  ## Example
      {:ok, _result, state} = LibSqlEx.Native.execute_non_trx(query, state, ["Alice"])
      rowid = LibSqlEx.Native.get_last_insert_rowid(state)
  """
  def get_last_insert_rowid(%LibSqlEx.State{conn_id: conn_id} = _state) do
    last_insert_rowid(conn_id)
  end

  @doc """
  Get the number of rows modified by the last INSERT, UPDATE or DELETE statement.

  ## Parameters
    - state: The connection state

  ## Example
      {:ok, _result, state} = LibSqlEx.Native.execute_non_trx(query, state, [])
      num_changes = LibSqlEx.Native.get_changes(state)
  """
  def get_changes(%LibSqlEx.State{conn_id: conn_id} = _state) do
    changes(conn_id)
  end

  @doc """
  Get the total number of rows modified, inserted or deleted since the database connection was opened.

  ## Parameters
    - state: The connection state

  ## Example
      total = LibSqlEx.Native.get_total_changes(state)
  """
  def get_total_changes(%LibSqlEx.State{conn_id: conn_id} = _state) do
    total_changes(conn_id)
  end

  @doc """
  Check if the connection is in autocommit mode (not in a transaction).

  ## Parameters
    - state: The connection state

  ## Example
      autocommit? = LibSqlEx.Native.get_is_autocommit(state)
  """
  def get_is_autocommit(%LibSqlEx.State{conn_id: conn_id} = _state) do
    is_autocommit(conn_id)
  end

  @doc """
  Create a vector from a list of numbers for use in vector columns.

  ## Parameters
    - values: List of numbers (integers or floats)

  ## Example
      # Create a 3-dimensional vector
      vec = LibSqlEx.Native.vector([1.0, 2.0, 3.0])
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
      column_def = LibSqlEx.Native.vector_type(3)  # "F32_BLOB(3)"
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
      distance_sql = LibSqlEx.Native.vector_distance_cos("embedding", [1.0, 2.0, 3.0])
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
      {:ok, results} = LibSqlEx.Native.batch(state, statements)
  """
  def batch(%LibSqlEx.State{conn_id: conn_id, mode: mode, sync: syncx} = _state, statements) do
    case execute_batch(conn_id, mode, syncx, statements) do
      results when is_list(results) ->
        # Convert each result to LibSqlEx.Result struct
        parsed_results =
          Enum.map(results, fn result ->
            case result do
              %{"columns" => columns, "rows" => rows, "num_rows" => num_rows} ->
                %LibSqlEx.Result{
                  command: :batch,
                  columns: columns,
                  rows: rows,
                  num_rows: num_rows
                }

              _ ->
                %LibSqlEx.Result{command: :batch}
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
      {:ok, results} = LibSqlEx.Native.batch_transactional(state, statements)
  """
  def batch_transactional(
        %LibSqlEx.State{conn_id: conn_id, mode: mode, sync: syncx} = _state,
        statements
      ) do
    case execute_transactional_batch(conn_id, mode, syncx, statements) do
      results when is_list(results) ->
        # Convert each result to LibSqlEx.Result struct
        parsed_results =
          Enum.map(results, fn result ->
            case result do
              %{"columns" => columns, "rows" => rows, "num_rows" => num_rows} ->
                %LibSqlEx.Result{
                  command: :batch,
                  columns: columns,
                  rows: rows,
                  num_rows: num_rows
                }

              _ ->
                %LibSqlEx.Result{command: :batch}
            end
          end)

        {:ok, parsed_results}

      {:error, message} ->
        {:error, message}
    end
  end
end
