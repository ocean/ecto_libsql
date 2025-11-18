defmodule EctoLibSql.Native do
  @moduledoc """
  Native interface module for LibSQL database operations.

  This module provides the bridge between Elixir and the underlying Rust NIF
  (Native Implemented Function) layer that interfaces with the LibSQL database.
  It includes both low-level NIF stubs and high-level Elixir convenience functions.

  ## Architecture

  The module is organized into three layers:

  1. **NIF Stubs** - Direct FFI bindings to Rust functions (lines 7-36)
  2. **Helper Functions** - Higher-level Elixir wrappers around NIFs
  3. **Utility Functions** - Convenience functions for common operations

  ## Features

    * Connection management (connect, ping, close)
    * Query execution (parameterized queries, prepared statements)
    * Transaction support (begin, commit, rollback with behaviors)
    * Batch operations (standard and transactional)
    * Cursor support for large result sets
    * Vector operations for similarity search
    * Database metadata (last insert ID, row counts, autocommit status)
    * Synchronization for remote replicas

  ## Usage

  Most functions in this module expect an `EctoLibSql.State` struct that contains
  the connection information. The higher-level API is provided by the main
  `EctoLibSql` module which implements the DBConnection behavior.

  For direct usage of prepared statements, batch operations, or vector features,
  this module provides the necessary functions.

  """

  use Rustler,
    otp_app: :ecto_libsql,
    crate: :ecto_libsql

  # Native bridge functions implemented in Rust (see native/ecto_libsql/src/lib.rs)

  @doc """
  Pings a connection to check if it's alive. Returns `true` if the connection is active.

  This is a NIF stub implemented in Rust.
  """
  def ping(_conn), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Establishes a connection to LibSQL database. Returns a connection ID on success.

  This is a NIF stub implemented in Rust.

  ## Parameters
    * `opts` - Connection options keyword list (`:uri`, `:auth_token`, `:database`, etc.)
    * `mode` - Connection mode (`:local`, `:remote`, or `:remote_replica`)
  """
  def connect(_opts, _mode), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Executes a query with arguments. Returns a map with columns, rows, and row count.

  This is a NIF stub implemented in Rust.

  ## Parameters
    * `conn` - Connection ID
    * `mode` - Connection mode
    * `sync` - Sync setting (`:enable_sync` or `:disable_sync`)
    * `query` - SQL query string
    * `args` - List of query parameters
  """
  def query_args(_conn, _mode, _sync, _query, _args), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Begins a transaction with default (deferred) behavior.

  This is a NIF stub implemented in Rust.
  """
  def begin_transaction(_conn), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Begins a transaction with specified behavior.

  This is a NIF stub implemented in Rust.

  ## Parameters
    * `conn` - Connection ID
    * `behavior` - Transaction behavior (`:deferred`, `:immediate`, or `:exclusive`)
  """
  def begin_transaction_with_behavior(_conn, _behavior), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Executes a query within an active transaction.

  This is a NIF stub implemented in Rust.

  ## Parameters
    * `trx_id` - Transaction ID
    * `query` - SQL query string
    * `args` - List of query parameters
  """
  def execute_with_transaction(_trx_id, _query, _args), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Checks the status of a transaction.

  This is a NIF stub implemented in Rust.
  """
  def handle_status_transaction(_trx_id), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Commits or rolls back a transaction.

  This is a NIF stub implemented in Rust.

  ## Parameters
    * `trx` - Transaction ID
    * `conn` - Connection ID
    * `mode` - Connection mode
    * `sync` - Sync setting
    * `param` - "commit" or "rollback"
  """
  def commit_or_rollback_transaction(_trx, _conn, _mode, _sync, _param),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Manually synchronizes a remote replica with the primary database.

  This is a NIF stub implemented in Rust.
  """
  def do_sync(_conn, _mode), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Closes a connection, statement, or cursor resource.

  This is a NIF stub implemented in Rust.

  ## Parameters
    * `id` - Resource ID to close
    * `opt` - Resource type (`:conn_id`, `:stmt_id`, or `:cursor_id`)
  """
  def close(_id, _opt), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Executes a batch of statements non-transactionally.

  This is a NIF stub implemented in Rust.
  """
  def execute_batch(_conn, _mode, _sync, _statements), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Executes a batch of statements within a transaction.

  This is a NIF stub implemented in Rust.
  """
  def execute_transactional_batch(_conn, _mode, _sync, _statements),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Prepares a SQL statement and returns a statement ID.

  This is a NIF stub implemented in Rust.
  """
  def prepare_statement(_conn, _sql), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Queries using a prepared statement (for SELECT queries).

  This is a NIF stub implemented in Rust.
  """
  def query_prepared(_conn, _stmt_id, _mode, _sync, _args), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Executes a prepared statement (for INSERT/UPDATE/DELETE queries).

  This is a NIF stub implemented in Rust.
  """
  def execute_prepared(_conn, _stmt_id, _mode, _sync, _args, _sql_hint),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets the rowid of the last inserted row.

  This is a NIF stub implemented in Rust.
  """
  def last_insert_rowid(_conn), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets the number of rows changed by the last statement.

  This is a NIF stub implemented in Rust.
  """
  def changes(_conn), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets the total number of rows changed since connection was opened.

  This is a NIF stub implemented in Rust.
  """
  def total_changes(_conn), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Checks if the connection is in autocommit mode.

  This is a NIF stub implemented in Rust.
  """
  def is_autocommit(_conn), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Declares a cursor for streaming large result sets.

  This is a NIF stub implemented in Rust.
  """
  def declare_cursor(_conn, _sql, _args), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Fetches the next batch of rows from a cursor.

  This is a NIF stub implemented in Rust.
  """
  def fetch_cursor(_cursor_id, _max_rows), do: :erlang.nif_error(:nif_not_loaded)

  # Higher-level Elixir helper functions

  @doc """
  Synchronizes a remote replica with the primary database.

  This is a convenience wrapper around `do_sync/2`.

  ## Parameters
    * `state` - Connection state with `:conn_id` and `:mode`

  ## Returns
    * `:ok` on success
    * `{:error, reason}` on failure
  """
  def sync(%EctoLibSql.State{conn_id: conn_id, mode: mode} = _state) do
    do_sync(conn_id, mode)
  end

  @doc """
  Closes a connection resource.

  This is a convenience wrapper around `close/2` that handles error formatting.

  ## Parameters
    * `id` - Resource ID to close
    * `opt` - Resource type (`:conn_id`, `:stmt_id`, or `:cursor_id`)
    * `state` - Connection state for error context

  ## Returns
    * `:ok` on success
    * `{:error, message, state}` on failure
  """
  def close_conn(id, opt, state) do
    case close(id, opt) do
      :ok -> :ok
      {:error, message} -> {:error, message, state}
    end
  end

  @doc """
  Executes a query outside of a transaction.

  This is a convenience wrapper that delegates to `query/3`.

  ## Parameters
    * `query` - Query struct
    * `state` - Connection state
    * `args` - Query parameters

  ## Returns
    * `{:ok, query, result, state}` on success
    * `{:error, query, message, state}` on failure
  """
  def execute_non_trx(query, state, args) do
    query(state, query, args)
  end

  @doc """
  Executes a parameterized query and returns the result.

  ## Parameters
    * `state` - Connection state
    * `query` - Query struct with `:statement` field
    * `args` - List of query parameters

  ## Returns
    * `{:ok, query, result, state}` - Success with result struct
    * `{:error, query, message, state}` - Failure with error message

  ## Example
      query = %EctoLibSql.Query{statement: "SELECT * FROM users WHERE id = ?"}
      {:ok, query, result, state} = EctoLibSql.Native.query(state, query, [42])
  """
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
        result = %EctoLibSql.Result{
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

  @doc """
  Executes a query within an active transaction.

  ## Parameters
    * `state` - Connection state with active `:trx_id`
    * `query` - Query struct with `:statement` field
    * `args` - List of query parameters

  ## Returns
    * `{:ok, query, result, state}` - Success with result struct
    * `{:error, query, message, state}` - Failure with error message

  ## Example
      {:ok, state} = EctoLibSql.Native.begin(state)
      query = %EctoLibSql.Query{statement: "INSERT INTO users (name) VALUES (?)"}
      {:ok, query, result, state} = EctoLibSql.Native.execute_with_trx(state, query, ["Alice"])
  """
  def execute_with_trx(
        %EctoLibSql.State{conn_id: _conn_id, trx_id: trx_id} = state,
        %EctoLibSql.Query{statement: statement} = query,
        args
      ) do
    case execute_with_transaction(trx_id, statement, args) do
      num_rows when is_integer(num_rows) ->
        result = %EctoLibSql.Result{
          command: detect_command(statement),
          num_rows: num_rows
        }

        {:ok, query, result, state}

      {:error, message} ->
        {:error, query, message, state}
    end
  end

  @doc """
  Begins a new database transaction.

  ## Parameters
    * `state` - Connection state
    * `opts` - Options keyword list
      * `:behavior` - Transaction behavior (`:deferred`, `:immediate`, or `:exclusive`), defaults to `:deferred`

  ## Returns
    * `{:ok, new_state}` - Success with updated state containing `:trx_id`
    * `{:error, reason}` - Failure with error reason

  ## Transaction Behaviors

    * `:deferred` - Transaction starts when first statement is executed (default)
    * `:immediate` - Transaction acquires reserved lock immediately
    * `:exclusive` - Transaction acquires exclusive lock immediately

  ## Example
      {:ok, state} = EctoLibSql.Native.begin(state, behavior: :immediate)
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
  Commits the current transaction.

  ## Parameters
    * `state` - Connection state with active `:trx_id`

  ## Returns
    * `{:ok, result}` on success
    * `{:error, reason}` on failure

  ## Example
      {:ok, state} = EctoLibSql.Native.begin(state)
      # ... execute queries ...
      {:ok, _} = EctoLibSql.Native.commit(state)
  """
  def commit(%EctoLibSql.State{conn_id: conn_id, trx_id: trx_id, mode: mode, sync: syncx} = _state) do
    commit_or_rollback_transaction(trx_id, conn_id, mode, syncx, "commit")
  end

  @doc """
  Rolls back the current transaction.

  ## Parameters
    * `state` - Connection state with active `:trx_id`

  ## Returns
    * `{:ok, result}` on success
    * `{:error, reason}` on failure

  ## Example
      {:ok, state} = EctoLibSql.Native.begin(state)
      # ... execute queries ...
      {:ok, _} = EctoLibSql.Native.rollback(state)
  """
  def rollback(
        %EctoLibSql.State{conn_id: conn_id, trx_id: trx_id, mode: mode, sync: syncx} = _state
      ) do
    commit_or_rollback_transaction(trx_id, conn_id, mode, syncx, "rollback")
  end

  @doc """
  Detects the SQL command type from a query string.

  Parses the first word of the SQL statement to determine its type.

  ## Parameters
    * `query` - SQL query string

  ## Returns
  An atom representing the command type: `:select`, `:insert`, `:update`,
  `:delete`, `:begin`, `:commit`, `:create`, `:rollback`, or `:unknown`

  ## Examples
      iex> EctoLibSql.Native.detect_command("SELECT * FROM users")
      :select

      iex> EctoLibSql.Native.detect_command("INSERT INTO users (name) VALUES (?)")
      :insert
  """
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
  Prepares a SQL statement for later execution.

  Prepared statements can be executed multiple times with different parameters,
  improving performance for repeated queries.

  ## Parameters
    * `state` - Connection state
    * `sql` - SQL query string to prepare

  ## Returns
    * `{:ok, stmt_id}` - Success with statement ID
    * `{:error, reason}` - Failure with error reason

  ## Example
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "SELECT * FROM users WHERE id = ?")
      {:ok, result} = EctoLibSql.Native.query_stmt(state, stmt_id, [42])
      :ok = EctoLibSql.Native.close_stmt(stmt_id)
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
  Executes a prepared statement with arguments (for non-SELECT queries).

  Returns the number of affected rows. Use `query_stmt/3` for SELECT queries.

  ## Parameters
    * `state` - Connection state
    * `stmt_id` - Statement ID from `prepare/2`
    * `sql` - Original SQL string (used for sync detection)
    * `args` - List of parameters to bind to the statement

  ## Returns
    * `{:ok, rows_affected}` - Success with number of rows affected
    * `{:error, reason}` - Failure with error reason

  ## Example
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "INSERT INTO users (name) VALUES (?)")
      {:ok, 1} = EctoLibSql.Native.execute_stmt(state, stmt_id, "INSERT INTO users (name) VALUES (?)", ["Alice"])
  """
  def execute_stmt(
        %EctoLibSql.State{conn_id: conn_id, mode: mode, sync: syncx} = _state,
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
  Queries using a prepared statement (for SELECT queries).

  Returns the result set including columns and rows. Use `execute_stmt/4` for
  INSERT/UPDATE/DELETE queries.

  ## Parameters
    * `state` - Connection state
    * `stmt_id` - Statement ID from `prepare/2`
    * `args` - List of parameters to bind to the statement

  ## Returns
    * `{:ok, result}` - Success with `EctoLibSql.Result` struct
    * `{:error, reason}` - Failure with error reason

  ## Example
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "SELECT * FROM users WHERE id = ?")
      {:ok, result} = EctoLibSql.Native.query_stmt(state, stmt_id, [42])
      # result.columns => ["id", "name", "email"]
      # result.rows => [[42, "Alice", "alice@example.com"]]
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
  Closes a prepared statement and frees its resources.

  ## Parameters
    * `stmt_id` - Statement ID to close

  ## Returns
    * `:ok` on success
    * `{:error, reason}` on failure

  ## Example
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "SELECT * FROM users WHERE id = ?")
      # ... use statement ...
      :ok = EctoLibSql.Native.close_stmt(stmt_id)
  """
  def close_stmt(stmt_id) do
    close(stmt_id, :stmt_id)
  end

  @doc """
  Gets the rowid of the last inserted row.

  This function returns the rowid (SQLite's internal row identifier) of the most
  recently inserted row in the current connection.

  ## Parameters
    * `state` - Connection state

  ## Returns
  Integer representing the last inserted rowid

  ## Example
      query = %EctoLibSql.Query{statement: "INSERT INTO users (name) VALUES (?)"}
      {:ok, _query, _result, state} = EctoLibSql.Native.execute_non_trx(query, state, ["Alice"])
      rowid = EctoLibSql.Native.get_last_insert_rowid(state)
  """
  def get_last_insert_rowid(%EctoLibSql.State{conn_id: conn_id} = _state) do
    last_insert_rowid(conn_id)
  end

  @doc """
  Gets the number of rows modified by the last INSERT, UPDATE, or DELETE statement.

  This returns the count for the most recently executed modifying statement on
  this connection.

  ## Parameters
    * `state` - Connection state

  ## Returns
  Integer representing the number of changed rows

  ## Example
      query = %EctoLibSql.Query{statement: "UPDATE users SET active = 1"}
      {:ok, _query, _result, state} = EctoLibSql.Native.execute_non_trx(query, state, [])
      num_changes = EctoLibSql.Native.get_changes(state)
  """
  def get_changes(%EctoLibSql.State{conn_id: conn_id} = _state) do
    changes(conn_id)
  end

  @doc """
  Gets the total number of rows modified, inserted, or deleted since the connection was opened.

  This is a cumulative count across all statements executed on this connection.

  ## Parameters
    * `state` - Connection state

  ## Returns
  Integer representing the total number of changed rows

  ## Example
      total = EctoLibSql.Native.get_total_changes(state)
  """
  def get_total_changes(%EctoLibSql.State{conn_id: conn_id} = _state) do
    total_changes(conn_id)
  end

  @doc """
  Checks if the connection is in autocommit mode (not in a transaction).

  Returns `true` if no transaction is active, `false` if inside a transaction.

  ## Parameters
    * `state` - Connection state

  ## Returns
  Boolean indicating autocommit status

  ## Example
      autocommit? = EctoLibSql.Native.get_is_autocommit(state)
  """
  def get_is_autocommit(%EctoLibSql.State{conn_id: conn_id} = _state) do
    is_autocommit(conn_id)
  end

  @doc """
  Creates a vector from a list of numbers for use in vector columns.

  Converts an Elixir list of numbers into the string format required for LibSQL
  vector columns: `"[1.0,2.0,3.0]"`.

  ## Parameters
    * `values` - List of numbers (integers or floats)

  ## Returns
  String representation of the vector

  ## Example
      # Create a 3-dimensional vector
      vec = EctoLibSql.Native.vector([1.0, 2.0, 3.0])
      # vec => "[1.0,2.0,3.0]"
      # Use in query: "INSERT INTO items (embedding) VALUES (?)"
  """
  def vector(values) when is_list(values) do
    "[#{Enum.join(values, ",")}]"
  end

  @doc """
  Generates a vector column type definition for CREATE TABLE statements.

  Creates the appropriate type string for defining vector columns in LibSQL.

  ## Parameters
    * `dimensions` - Number of dimensions (must be positive integer)
    * `type` - Vector element type, either `:f32` (float32) or `:f64` (float64), defaults to `:f32`

  ## Returns
  String representing the column type (e.g., `"F32_BLOB(3)"`)

  ## Example
      column_def = EctoLibSql.Native.vector_type(3)  # => "F32_BLOB(3)"
      # Use in: "CREATE TABLE items (id INTEGER PRIMARY KEY, embedding \#{column_def})"

      column_def = EctoLibSql.Native.vector_type(128, :f64)  # => "F64_BLOB(128)"
  """
  def vector_type(dimensions, type \\ :f32) when is_integer(dimensions) and dimensions > 0 do
    case type do
      :f32 -> "F32_BLOB(#{dimensions})"
      :f64 -> "F64_BLOB(#{dimensions})"
      _ -> raise ArgumentError, "type must be :f32 or :f64"
    end
  end

  @doc """
  Generates SQL for cosine distance vector similarity search.

  Creates a `vector_distance_cos()` function call for use in ORDER BY clauses
  when performing similarity searches.

  ## Parameters
    * `column` - Name of the vector column
    * `vector` - Query vector (list of numbers or vector string)

  ## Returns
  String containing the SQL function call

  ## Example
      distance_sql = EctoLibSql.Native.vector_distance_cos("embedding", [1.0, 2.0, 3.0])
      # => "vector_distance_cos(embedding, '[1.0,2.0,3.0]')"

      # Use in query:
      query = "SELECT * FROM items ORDER BY \#{distance_sql} LIMIT 10"
  """
  def vector_distance_cos(column, vector) when is_binary(column) do
    vec_str = if is_list(vector), do: vector(vector), else: vector
    "vector_distance_cos(#{column}, '#{vec_str}')"
  end

  @doc """
  Executes a batch of SQL statements non-transactionally.

  Each statement is executed independently. If one fails, others may still succeed.
  Use `batch_transactional/2` for atomic execution.

  ## Parameters
    * `state` - Connection state
    * `statements` - List of `{sql, args}` tuples where:
      * `sql` - SQL statement string
      * `args` - List of parameters for the statement

  ## Returns
    * `{:ok, results}` - Success with list of `EctoLibSql.Result` structs
    * `{:error, message}` - Failure with error message

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
  Executes a batch of SQL statements within a transaction.

  All statements are executed atomically - if any statement fails, all changes
  are rolled back. This provides ACID guarantees for the batch.

  ## Parameters
    * `state` - Connection state
    * `statements` - List of `{sql, args}` tuples where:
      * `sql` - SQL statement string
      * `args` - List of parameters for the statement

  ## Returns
    * `{:ok, results}` - Success with list of `EctoLibSql.Result` structs
    * `{:error, message}` - Failure with error message (all changes rolled back)

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
