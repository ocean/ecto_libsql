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

  mix_config = Mix.Project.config()
  version = mix_config[:version]
  github_url = mix_config[:package][:links]["GitHub"]
  mode = if Mix.env() in [:dev, :test], do: :debug, else: :release

  use RustlerPrecompiled,
    otp_app: :ecto_libsql,
    crate: "ecto_libsql",
    version: version,
    base_url: "#{github_url}/releases/download/v#{version}",
    targets: ~w(
      aarch64-apple-darwin
      aarch64-unknown-linux-gnu
      aarch64-unknown-linux-musl
      x86_64-apple-darwin
      x86_64-unknown-linux-gnu
      x86_64-unknown-linux-musl
    ),
    nif_versions: ["2.15"],
    mode: mode,
    force_build: System.get_env("ECTO_LIBSQL_BUILD") in ["1", "true"]

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

  @doc false
  def set_busy_timeout(_conn_id, _timeout_ms), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def reset_connection(_conn_id), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def interrupt_connection(_conn_id), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def enable_load_extension(_conn_id, _enabled), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def load_extension(_conn_id, _path, _entry_point), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def set_update_hook(_conn_id, _pid), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def clear_update_hook(_conn_id), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def set_authorizer(_conn_id, _pid), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def should_use_query_path(_sql), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def pragma_query(_conn_id, _pragma_stmt), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def execute_batch_native(_conn_id, _sql), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def execute_transactional_batch_native(_conn_id, _sql), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def statement_column_count(_conn_id, _stmt_id), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def statement_column_name(_conn_id, _stmt_id, _idx), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def statement_parameter_count(_conn_id, _stmt_id), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def statement_parameter_name(_conn_id, _stmt_id, _idx), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def reset_statement(_conn_id, _stmt_id), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def get_statement_columns(_conn_id, _stmt_id), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def savepoint(_conn_id, _trx_id, _name), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def release_savepoint(_conn_id, _trx_id, _name), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def rollback_to_savepoint(_conn_id, _trx_id, _name), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def get_frame_number(_conn_id), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def sync_until(_conn_id, _frame_no), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def flush_replicator(_conn_id), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Get the highest frame number from write operations (for read-your-writes consistency).

  This is a low-level NIF function that returns the maximum replication frame
  number from write operations on this database connection. It's primarily used
  internally by `get_max_write_frame/1`.

  For most use cases, use `get_max_write_frame/1` instead, which provides better
  error handling and documentation.

  ## Parameters
    - conn_id: The connection ID (string)

  ## Returns
    - Integer frame number (0 if no writes tracked)
    - `{:error, reason}` if the connection is invalid

  ## Notes
    - This is a raw NIF function - prefer `get_max_write_frame/1` for normal usage
    - Returns 0 for local databases (not applicable)
    - Frame number increases with each write operation
    - Essential for implementing read-your-writes consistency in multi-replica setups

  """
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
  @spec sync(EctoLibSql.State.t()) :: {:ok, String.t()} | {:error, term()}
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

  @doc """
  Normalise query arguments to a positional parameter list.

  ## Arguments

  - `conn_id` - The connection identifier
  - `statement` - The SQL statement (used for named parameter introspection)
  - `args` - The arguments to normalise; must be a list or map

  ## Returns

  - `list` - Positional parameter list on success
  - `{:error, reason}` - Error tuple if args is invalid or map conversion fails

  ## Accepted Types

  - **List**: Returned as-is (positional parameters)
  - **Map**: Converted to positional list using statement parameter introspection

  Any other type returns `{:error, "arguments must be a list or map"}`.
  """
  @spec normalise_arguments(String.t(), String.t(), list() | map()) ::
          list() | {:error, term()}
  def normalise_arguments(conn_id, statement, args) do
    case args do
      list when is_list(list) ->
        list

      map when is_map(map) ->
        # Convert named parameters map to positional list.
        # Returns list on success, {:error, reason} on preparation failure.
        map_to_positional_args(conn_id, statement, map)

      _other ->
        {:error, "arguments must be a list or map"}
    end
  end

  @doc false
  defp remove_param_prefix(name) when is_binary(name) do
    case String.first(name) do
      ":" -> String.slice(name, 1..-1//1)
      "@" -> String.slice(name, 1..-1//1)
      "$" -> String.slice(name, 1..-1//1)
      _ -> name
    end
  end

  @doc false
  # Extract a parameter name at the given index from a prepared statement.
  # Returns the name with prefix removed, or nil if lookup fails.
  defp extract_param_name(conn_id, stmt_id, idx) do
    case statement_parameter_name(conn_id, stmt_id, idx) do
      name when is_binary(name) ->
        # Remove prefix (:, @, $) if present. Keep as string.
        remove_param_prefix(name)

      nil ->
        # Positional parameter (?) - use nil as marker.
        nil

      {:error, _reason} ->
        # Parameter name lookup failed, use nil as fallback.
        nil

      _ ->
        nil
    end
  end

  @doc false
  # Convert a map of named parameters to a positional list using statement introspection.
  # Returns list on success, {:error, reason} on failure.
  defp convert_map_to_positional(conn_id, stmt_id, map) do
    case statement_parameter_count(conn_id, stmt_id) do
      count when is_integer(count) and count >= 0 ->
        param_names =
          if count == 0,
            do: [],
            else: Enum.map(1..count, &extract_param_name(conn_id, stmt_id, &1))

        # Convert map to positional list using the names.
        # Support both atom and string keys in the input map.
        Enum.map(param_names, &get_map_value_flexible(map, &1))

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  # Check if a map has a key, supporting both atom and string keys.
  # This avoids creating atoms at runtime while allowing users to pass
  # either %{name: value} or %{"name" => value}.
  defp has_map_key_flexible?(_map, nil), do: false

  defp has_map_key_flexible?(map, name) when is_binary(name) do
    # Try atom key first (more common), then string key.
    atom_key = String.to_existing_atom(name)
    Map.has_key?(map, atom_key) or Map.has_key?(map, name)
  rescue
    ArgumentError ->
      # Atom doesn't exist, check string key only.
      Map.has_key?(map, name)
  end

  # Get a value from a map, supporting both atom and string keys.
  # This avoids creating atoms at runtime while allowing users to pass
  # either %{name: value} or %{"name" => value}.
  defp get_map_value_flexible(_map, nil), do: nil

  defp get_map_value_flexible(map, name) when is_binary(name) do
    # Try atom key first (more common), then string key.
    atom_key = String.to_existing_atom(name)
    Map.get(map, atom_key, Map.get(map, name, nil))
  rescue
    ArgumentError ->
      # Atom doesn't exist, try string key only.
      Map.get(map, name, nil)
  end

  # Validate that all required parameters exist in the map.
  # Raises ArgumentError if any parameters are missing or if map is used with positional params.
  defp validate_params_exist(param_map, param_names) do
    # Check if we have positional parameters (nil entries from ?).
    has_positional = Enum.any?(param_names, &is_nil/1)

    if has_positional do
      # SQL uses positional parameters (?), but user provided a map.
      # This is a type mismatch - positional params require a list.
      raise ArgumentError,
            "Cannot use named parameter map with SQL that has positional parameters (?). " <>
              "Use a list of values instead, e.g., [value1, value2] not %{key: value}"
    end

    # Filter out any nil names (shouldn't happen after above check, but defensive).
    named_params = Enum.reject(param_names, &is_nil/1)

    # Validate that all named parameters exist in the map.
    missing_params =
      Enum.filter(named_params, fn name ->
        not has_map_key_flexible?(param_map, name)
      end)

    if missing_params != [] do
      missing_list = Enum.map_join(missing_params, ", ", &":#{&1}")
      all_params = Enum.map_join(named_params, ", ", &":#{&1}")

      raise ArgumentError,
            "Missing required parameters: #{missing_list}. " <>
              "SQL requires: #{all_params}"
    end

    :ok
  end

  # ETS-based LRU cache for parameter metadata.
  # Unlike persistent_term, this cache has a maximum size and evicts old entries.
  # This prevents unbounded memory growth from dynamic SQL workloads.
  #
  # Memory considerations:
  # - Maximum 1000 entries, evicts 500 oldest when full
  # - Each entry stores: SQL statement string, list of parameter names, access timestamp
  # - For applications with many unique dynamic queries (e.g., dynamic filters, search),
  #   the cache may consume several MB depending on query complexity
  # - Use clear_param_cache/0 to reclaim memory if needed
  # - Use param_cache_size/0 to monitor cache utilisation
  @param_cache_table :ecto_libsql_param_cache
  @param_cache_max_size 1000
  @param_cache_evict_count 500

  @doc """
  Clear the parameter name cache.

  The cache stores SQL statements and their parameter name mappings to avoid
  repeated introspection overhead. Each entry contains the full SQL string,
  parameter names list, and access timestamp.

  Use this function to:
  - Reclaim memory in applications with many dynamic queries
  - Reset cache state during testing
  - Force re-introspection after schema changes

  The cache will be automatically rebuilt as queries are executed.
  Use `param_cache_size/0` to monitor cache utilisation before clearing.
  """
  @spec clear_param_cache() :: :ok
  def clear_param_cache do
    case :ets.whereis(@param_cache_table) do
      :undefined -> :ok
      _ref -> :ets.delete_all_objects(@param_cache_table)
    end

    :ok
  end

  @doc """
  Get the current size of the parameter name cache.

  Returns the number of cached SQL statement parameter mappings.
  The cache has a maximum size of #{@param_cache_max_size} entries.

  Useful for monitoring cache utilisation in applications with dynamic queries.
  If the cache frequently hits the maximum, consider whether query patterns
  could be optimised to reduce unique SQL variations.
  """
  @spec param_cache_size() :: non_neg_integer()
  def param_cache_size do
    case :ets.whereis(@param_cache_table) do
      :undefined -> 0
      _ref -> :ets.info(@param_cache_table, :size)
    end
  end

  @doc false
  defp ensure_param_cache_table do
    case :ets.whereis(@param_cache_table) do
      :undefined ->
        # Create the table with read_concurrency for fast lookups.
        # Use try/rescue to handle race condition where another process
        # creates the table between whereis and new.
        try do
          :ets.new(@param_cache_table, [
            :set,
            :public,
            :named_table,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          ArgumentError ->
            # Table was created by another process, that's fine.
            :ok
        end

      _ref ->
        :ok
    end
  end

  @doc false
  defp get_cached_param_names(statement) do
    ensure_param_cache_table()

    case :ets.lookup(@param_cache_table, statement) do
      [{^statement, param_names, _access_time}] ->
        # Update access time synchronously for correct LRU tracking.
        # ETS updates are fast (microseconds), so no need for async.
        :ets.update_element(@param_cache_table, statement, {3, System.monotonic_time()})
        param_names

      [] ->
        nil
    end
  end

  @doc false
  defp cache_param_names(statement, param_names) do
    ensure_param_cache_table()

    # Check cache size and evict if needed.
    cache_size = :ets.info(@param_cache_table, :size)

    if cache_size >= @param_cache_max_size do
      evict_oldest_entries()
    end

    # Insert with current access time.
    :ets.insert(@param_cache_table, {statement, param_names, System.monotonic_time()})
    param_names
  end

  @doc false
  defp evict_oldest_entries do
    # Get all entries with their access times.
    entries = :ets.tab2list(@param_cache_table)

    # Sort by access time (oldest first) and take the ones to evict.
    entries
    |> Enum.sort_by(fn {_stmt, _names, access_time} -> access_time end)
    |> Enum.take(@param_cache_evict_count)
    |> Enum.each(fn {stmt, _names, _time} -> :ets.delete(@param_cache_table, stmt) end)
  end

  @doc false
  defp map_to_positional_args(conn_id, statement, param_map) do
    # Check cache first to avoid repeated preparation overhead.
    case get_cached_param_names(statement) do
      nil ->
        # Cache miss - introspect and cache parameter names.
        # Returns list on success, {:error, reason} on failure.
        introspect_and_cache_params(conn_id, statement, param_map)

      param_names ->
        # Cache hit - validate parameters exist before conversion (raises on missing params).
        validate_params_exist(param_map, param_names)

        # Convert map to positional list using cached order.
        # Support both atom and string keys in the input map.
        Enum.map(param_names, fn name ->
          get_map_value_flexible(param_map, name)
        end)
    end
  end

  @doc false
  defp introspect_and_cache_params(conn_id, statement, param_map) do
    # Prepare the statement to introspect parameters.
    stmt_id = prepare_statement(conn_id, statement)

    # stmt_id is a string UUID on success, or error tuple on failure.
    case stmt_id do
      stmt_id when is_binary(stmt_id) ->
        # Get parameter count, propagating errors instead of silently falling back to 0.
        case statement_parameter_count(conn_id, stmt_id) do
          count when is_integer(count) and count >= 0 ->
            # Extract parameter names in order (kept as strings to avoid atom creation).
            param_names =
              if count == 0 do
                []
              else
                Enum.map(1..count, &extract_param_name(conn_id, stmt_id, &1))
              end

            # Clean up prepared statement.
            close_stmt(stmt_id)

            # Cache the parameter names for future calls.
            cache_param_names(statement, param_names)

            # Validate that all required parameters exist in the map (raises on missing params).
            validate_params_exist(param_map, param_names)

            # Convert map to positional list using the names.
            # Support both atom and string keys in the input map.
            Enum.map(param_names, fn name ->
              get_map_value_flexible(param_map, name)
            end)

          {:error, reason} ->
            # Clean up prepared statement before returning error.
            close_stmt(stmt_id)
            {:error, reason}
        end

      {:error, reason} ->
        # Propagate the preparation error to callers.
        {:error, reason}
    end
  end

  @doc false
  # Normalise arguments for prepared statements using stmt_id introspection.
  # This avoids re-preparing the statement since we already have the stmt_id.
  # Returns list on success, {:error, reason} on failure.
  def normalise_arguments_for_stmt(conn_id, stmt_id, args) do
    case args do
      list when is_list(list) ->
        # Already positional, return as-is.
        list

      map when is_map(map) ->
        # Convert named parameters map to positional list using stmt introspection.
        # Propagate errors instead of silently treating them as zero-parameter statements.
        convert_map_to_positional(conn_id, stmt_id, map)

      _ ->
        {:error, "arguments must be a list or map"}
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
    # Convert named parameters (map) to positional parameters (list).
    # Returns {:error, reason} if parameter introspection fails.
    case normalise_arguments(conn_id, statement, args) do
      {:error, reason} ->
        {:error,
         %EctoLibSql.Error{
           message: "Failed to prepare statement for parameter introspection: #{reason}"
         }, state}

      args_for_execution ->
        do_query(conn_id, mode, syncx, statement, args_for_execution, query, state)
    end
  end

  @doc false
  defp do_query(conn_id, mode, syncx, statement, args_for_execution, query, state) do
    # Encode parameters to handle complex Elixir types (maps, etc.).
    encoded_args = encode_parameters(args_for_execution)

    case query_args(conn_id, mode, syncx, statement, encoded_args) do
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
        # Set them to nil to match Ecto's expectations for write operations
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
    # Convert named parameters (map) to positional parameters (list).
    # Returns {:error, reason} if parameter introspection fails.
    case normalise_arguments(conn_id, statement, args) do
      {:error, reason} ->
        {:error,
         %EctoLibSql.Error{
           message: "Failed to prepare statement for parameter introspection: #{reason}"
         }, state}

      args_for_execution ->
        do_execute_with_trx(conn_id, trx_id, statement, args_for_execution, query, state)
    end
  end

  @doc false
  defp do_execute_with_trx(conn_id, trx_id, statement, args_for_execution, query, state) do
    # Encode parameters to handle complex Elixir types (maps, etc.).
    encoded_args = encode_parameters(args_for_execution)

    # Detect the command type to route correctly.
    command = detect_command(statement)

    # For SELECT statements (even without RETURNING), use query_with_trx_args.
    # For INSERT/UPDATE/DELETE with RETURNING, use query_with_trx_args.
    # For INSERT/UPDATE/DELETE without RETURNING, use execute_with_transaction.
    # Use word-boundary regex to detect RETURNING precisely (matching Rust NIF behaviour).
    has_returning = Regex.match?(~r/\bRETURNING\b/i, statement)
    should_query = command == :select or has_returning

    if should_query do
      # Use query_with_trx_args for SELECT or statements with RETURNING.
      case query_with_trx_args(trx_id, conn_id, statement, encoded_args) do
        %{
          "columns" => columns,
          "rows" => rows,
          "num_rows" => num_rows
        } ->
          # For INSERT/UPDATE/DELETE without actual returned rows, normalise empty lists to nil
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
      case execute_with_transaction(trx_id, conn_id, statement, encoded_args) do
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
  @spec begin(EctoLibSql.State.t(), Keyword.t()) ::
          {:ok, EctoLibSql.State.t()} | {:error, term()}
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
  @spec commit(EctoLibSql.State.t()) :: {:ok, String.t()} | {:error, term()}
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
  @spec rollback(EctoLibSql.State.t()) :: {:ok, String.t()} | {:error, term()}
  def rollback(
        %EctoLibSql.State{conn_id: conn_id, trx_id: trx_id, mode: mode, sync: syncx} = _state
      ) do
    commit_or_rollback_transaction(trx_id, conn_id, mode, syncx, "rollback")
  end

  @doc """
  Detects the SQL command type from a query string.

  Returns an atom representing the command type, or `:unknown` for
  unrecognised commands.

  ## Examples

      iex> EctoLibSql.Native.detect_command("SELECT * FROM users")
      :select

      iex> EctoLibSql.Native.detect_command("INSERT INTO users VALUES (1)")
      :insert

  """
  @spec detect_command(String.t()) :: EctoLibSql.Result.command_type()
  def detect_command(query) when is_binary(query) do
    query
    |> skip_leading_comments_and_whitespace()
    |> extract_first_word()
    |> command_atom()
  end

  def detect_command(_), do: :unknown

  # Skip leading whitespace and SQL comments (both -- and /* */ styles).
  # This ensures queries starting with comments are correctly classified.
  defp skip_leading_comments_and_whitespace(query) do
    query
    |> String.trim_leading()
    |> do_skip_comments()
  end

  defp do_skip_comments(<<"--", rest::binary>>) do
    # Single-line comment: skip to end of line
    rest
    |> skip_to_newline()
    |> skip_leading_comments_and_whitespace()
  end

  defp do_skip_comments(<<"/*", rest::binary>>) do
    # Block comment: skip to closing */
    rest
    |> skip_to_block_end()
    |> skip_leading_comments_and_whitespace()
  end

  defp do_skip_comments(query), do: query

  defp skip_to_newline(<<"\n", rest::binary>>), do: rest
  defp skip_to_newline(<<"\r\n", rest::binary>>), do: rest
  defp skip_to_newline(<<_::binary-size(1), rest::binary>>), do: skip_to_newline(rest)
  defp skip_to_newline(<<>>), do: <<>>

  defp skip_to_block_end(<<"*/", rest::binary>>), do: rest
  defp skip_to_block_end(<<_::binary-size(1), rest::binary>>), do: skip_to_block_end(rest)
  defp skip_to_block_end(<<>>), do: <<>>

  defp extract_first_word(query) do
    # Extract first word more efficiently - stop at first whitespace
    first_word =
      case :binary.match(query, [" ", "\t", "\n", "\r", "("]) do
        {pos, _len} -> binary_part(query, 0, pos)
        :nomatch -> query
      end

    String.downcase(first_word)
  end

  # DML commands - data manipulation.
  defp command_atom("select"), do: :select
  defp command_atom("insert"), do: :insert
  defp command_atom("update"), do: :update
  defp command_atom("delete"), do: :delete

  # CTEs (Common Table Expressions) - WITH clauses are treated as select
  # since they typically return rows (the main query following the CTE is usually SELECT).
  defp command_atom("with"), do: :select

  # Transaction control commands.
  defp command_atom("begin"), do: :begin
  defp command_atom("commit"), do: :commit
  defp command_atom("rollback"), do: :rollback

  # DDL commands - schema modifications are grouped under :create since they
  # all modify database structure rather than data, and don't require distinct
  # handling in result processing.
  defp command_atom("create"), do: :create
  defp command_atom("drop"), do: :create
  defp command_atom("alter"), do: :create

  # SQLite-specific.
  defp command_atom("pragma"), do: :pragma

  # Catch-all for unrecognised commands.
  defp command_atom(_), do: :unknown

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
  Execute a prepared statement with arguments.

  Automatically routes to query_stmt if the statement returns rows (e.g., SELECT, EXPLAIN, RETURNING),
  or to execute_prepared if it doesn't (e.g., INSERT/UPDATE/DELETE without RETURNING).

  ## Parameters
    - state: The connection state
    - stmt_id: The statement ID from prepare/2
    - sql: The original SQL (for sync detection and statement type detection)
    - args: List of positional parameters OR map with atom keys for named parameters

  ## Examples

      # INSERT without RETURNING
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "INSERT INTO users (name) VALUES (?)")
      {:ok, num_rows} = EctoLibSql.Native.execute_stmt(state, stmt_id, sql, ["Alice"])

      # SELECT query
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "SELECT * FROM users WHERE id = ?")
      {:ok, result} = EctoLibSql.Native.execute_stmt(state, stmt_id, sql, [1])

      # EXPLAIN query
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "EXPLAIN QUERY PLAN SELECT * FROM users")
      {:ok, result} = EctoLibSql.Native.execute_stmt(state, stmt_id, sql, [])

      # INSERT with RETURNING
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "INSERT INTO users (name) VALUES (?) RETURNING *")
      {:ok, result} = EctoLibSql.Native.execute_stmt(state, stmt_id, sql, ["Alice"])
  """
  def execute_stmt(
        %EctoLibSql.State{conn_id: conn_id, mode: mode, sync: syncx} = state,
        stmt_id,
        sql,
        args
      ) do
    # Check if this statement returns rows (uses the NIF for consistency with handle_execute).
    case should_use_query_path(sql) do
      true ->
        # Use query_stmt path for statements that return rows.
        query_stmt(state, stmt_id, args)

      false ->
        # Use execute path for statements that don't return rows.
        # Normalise arguments (convert map to positional list if needed).
        case normalise_arguments_for_stmt(conn_id, stmt_id, args) do
          {:error, reason} ->
            {:error, "Failed to normalise parameters: #{reason}"}

          normalised_args ->
            case execute_prepared(conn_id, stmt_id, mode, syncx, sql, normalised_args) do
              num_rows when is_integer(num_rows) ->
                {:ok, num_rows}

              {:error, reason} ->
                {:error, reason}
            end
        end
    end
  end

  @doc """
  Query using a prepared statement (for SELECT queries).
  Returns the result set.

  ## Parameters
    - state: The connection state
    - stmt_id: The statement ID from prepare/2
    - args: List of positional parameters OR map with atom keys for named parameters

  ## Examples

      # Positional parameters
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "SELECT * FROM users WHERE id = ?")
      {:ok, result} = EctoLibSql.Native.query_stmt(state, stmt_id, [42])

      # Named parameters with atom keys
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "SELECT * FROM users WHERE id = :id")
      {:ok, result} = EctoLibSql.Native.query_stmt(state, stmt_id, %{id: 42})
  """
  def query_stmt(
        %EctoLibSql.State{conn_id: conn_id, mode: mode, sync: syncx} = _state,
        stmt_id,
        args
      ) do
    # Normalise arguments (convert map to positional list if needed).
    case normalise_arguments_for_stmt(conn_id, stmt_id, args) do
      {:error, reason} ->
        {:error, "Failed to normalise parameters: #{reason}"}

      normalised_args ->
        case query_prepared(conn_id, stmt_id, mode, syncx, normalised_args) do
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
    - statements: A list of tuples {sql, args} where sql is the SQL string
      and args is a list of parameters

  ## Example
      statements = [
        {"INSERT INTO users (name) VALUES (?)", ["Alice"]},
        {"INSERT INTO users (name) VALUES (?)", ["Bob"]},
        {"SELECT * FROM users", []}
      ]
      {:ok, results} = EctoLibSql.Native.batch(state, statements)
  """
  @spec batch(EctoLibSql.State.t(), list({String.t(), list()})) ::
          {:ok, list(EctoLibSql.Result.t())} | {:error, term()}
  def batch(%EctoLibSql.State{conn_id: conn_id, mode: mode, sync: syncx} = _state, statements) do
    conn_id
    |> execute_batch(mode, syncx, statements)
    |> parse_batch_results()
  end

  @doc """
  Execute a batch of SQL statements in a transaction. All statements are executed
  atomically - if any statement fails, all changes are rolled back.

  ## Parameters
    - state: The connection state
    - statements: A list of tuples {sql, args} where sql is the SQL string
      and args is a list of parameters

  ## Example
      statements = [
        {"INSERT INTO users (name) VALUES (?)", ["Alice"]},
        {"INSERT INTO users (name) VALUES (?)", ["Bob"]},
        {"UPDATE users SET active = 1", []}
      ]
      {:ok, results} = EctoLibSql.Native.batch_transactional(state, statements)
  """
  @spec batch_transactional(EctoLibSql.State.t(), list({String.t(), list()})) ::
          {:ok, list(EctoLibSql.Result.t())} | {:error, term()}
  def batch_transactional(
        %EctoLibSql.State{conn_id: conn_id, mode: mode, sync: syncx} = _state,
        statements
      ) do
    conn_id
    |> execute_transactional_batch(mode, syncx, statements)
    |> parse_batch_results()
  end

  # Parse batch execution results into EctoLibSql.Result structs.
  @spec parse_batch_results(list(map()) | {:error, term()}) ::
          {:ok, list(EctoLibSql.Result.t())} | {:error, term()}
  defp parse_batch_results(results) when is_list(results) do
    parsed_results =
      Enum.map(results, fn
        %{"columns" => columns, "rows" => rows, "num_rows" => num_rows} ->
          %EctoLibSql.Result{
            command: :batch,
            columns: columns,
            rows: rows,
            num_rows: num_rows
          }

        _other ->
          %EctoLibSql.Result{command: :batch}
      end)

    {:ok, parsed_results}
  end

  defp parse_batch_results({:error, message}), do: {:error, message}

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
  Enable or disable loading of SQLite extensions.

  By default, extension loading is disabled for security reasons.
  You must explicitly enable it before calling `load_ext/3`.

  ## Parameters
    - state: The connection state
    - enabled: Whether to enable (true) or disable (false) extension loading

  ## Returns
    - `:ok` - Extension loading enabled/disabled successfully
    - `{:error, reason}` - Operation failed

  ## Example

      # Enable extension loading
      :ok = EctoLibSql.Native.enable_extensions(state, true)

      # Load an extension
      :ok = EctoLibSql.Native.load_ext(state, "/path/to/extension.so")

      # Disable extension loading (recommended after loading)
      :ok = EctoLibSql.Native.enable_extensions(state, false)

  ## Security Warning

  ⚠️ Only enable extension loading if you trust the extensions being loaded.
  Malicious extensions can compromise database security and execute arbitrary code.

  """
  def enable_extensions(%EctoLibSql.State{conn_id: conn_id} = _state, enabled)
      when is_boolean(enabled) do
    enable_load_extension(conn_id, enabled)
  end

  @doc """
  Load a SQLite extension from a dynamic library file.

  Extensions must be enabled first via `enable_extensions/2`.

  ## Parameters
    - state: The connection state
    - path: Path to the extension dynamic library (.so, .dylib, or .dll)
    - entry_point: Optional entry point function name (defaults to extension-specific default)

  ## Returns
    - `:ok` - Extension loaded successfully
    - `{:error, reason}` - Extension loading failed

  ## Example

      # Enable extension loading first
      :ok = EctoLibSql.Native.enable_extensions(state, true)

      # Load an extension
      :ok = EctoLibSql.Native.load_ext(state, "/usr/lib/sqlite3/pcre.so")

      # Load with custom entry point
      :ok = EctoLibSql.Native.load_ext(state, "/path/to/extension.so", "sqlite3_extension_init")

      # Disable extension loading after
      :ok = EctoLibSql.Native.enable_extensions(state, false)

  ## Common Extensions

  - **FTS5** (full-text search) - Usually built-in, provides advanced full-text search
  - **JSON1** (JSON functions) - Usually built-in, provides JSON manipulation functions
  - **R-Tree** (spatial indexing) - Spatial data structures for geographic data
  - **PCRE** (regular expressions) - Perl-compatible regular expressions
  - Custom user-defined functions

  ## Security Warning

  ⚠️ Only load extensions from trusted sources. Extensions run with full database
  access and can execute arbitrary code.

  ## Notes

  - Extension loading must be enabled first via `enable_extensions/2`
  - Extensions are loaded per-connection, not globally
  - Some extensions may already be built into libsql (FTS5, JSON1)
  - Extension files must match your platform (.so on Linux, .dylib on macOS, .dll on Windows)

  """
  def load_ext(%EctoLibSql.State{conn_id: conn_id} = _state, path, entry_point \\ nil)
      when is_binary(path) do
    load_extension(conn_id, path, entry_point)
  end

  @doc """
  Install an update hook for monitoring database changes (CDC).

  **NOT SUPPORTED** - Update hooks require sending messages from managed BEAM threads,
  which is not allowed by Rustler's threading model.

  ## Why Not Supported

  SQLite's update hook callback is called synchronously during INSERT/UPDATE/DELETE operations,
  and runs on the same thread executing the SQL statement. In our NIF implementation:
  1. SQL execution happens on Erlang scheduler threads (managed by BEAM)
  2. Rustler's `OwnedEnv::send_and_clear()` can ONLY be called from unmanaged threads
  3. Calling `send_and_clear()` from a managed thread causes a panic

  This is a fundamental limitation of mixing NIF callbacks with Erlang's threading model.

  ## Alternatives

  For change data capture and real-time updates, consider:

  1. **Application-level events** - Emit events from your Ecto repos:

      defmodule MyApp.Repo do
        def insert(changeset, opts \\\\ []) do
          case Ecto.Repo.insert(__MODULE__, changeset, opts) do
            {:ok, record} = result ->
              Phoenix.PubSub.broadcast(MyApp.PubSub, "db_changes", {:insert, record})
              result
            error -> error
          end
        end
      end

  2. **Database triggers** - Use SQLite triggers to log changes to a separate table:

      CREATE TRIGGER users_audit_insert AFTER INSERT ON users
      BEGIN
        INSERT INTO audit_log (action, table_name, row_id, timestamp)
        VALUES ('insert', 'users', NEW.id, datetime('now'));
      END;

  3. **Polling-based CDC** - Periodically query for changes using timestamps or version columns

  4. **Phoenix.Tracker** - Track state changes at the application level

  ## Returns
    - `:unsupported` - Always returns unsupported

  """
  def add_update_hook(%EctoLibSql.State{} = state, pid \\ self()) do
    set_update_hook(state.conn_id, pid)
  end

  @doc """
  Remove the update hook from a connection.

  **NOT SUPPORTED** - Update hooks are not currently implemented.

  ## Returns
    - `:unsupported` - Always returns unsupported

  """
  def remove_update_hook(%EctoLibSql.State{conn_id: conn_id} = _state) do
    clear_update_hook(conn_id)
  end

  @doc """
  Install an authorizer hook for row-level security.

  **NOT SUPPORTED** - Authorizer hooks require synchronous bidirectional communication
  between Rust and Elixir, which is not feasible with Rustler's threading model.

  ## Why Not Supported

  SQLite's authorizer callback is called synchronously during query compilation and expects
  an immediate response (Allow/Deny/Ignore). This would require:
  1. Sending a message from Rust to Elixir
  2. Blocking the Rust thread waiting for a response
  3. Receiving the response from Elixir

  This pattern is not safe with Rustler because:
  - The callback runs on a SQLite thread (potentially holding locks)
  - Blocking on Erlang scheduler threads can cause deadlocks
  - No safe way to do synchronous Rust→Elixir→Rust calls

  ## Alternatives

  For row-level security and access control, consider:

  1. **Application-level authorization** - Check permissions in Elixir before queries:

      defmodule MyApp.Auth do
        def can_access?(user, table, action) do
          # Check user permissions
        end
      end

      def get_user(id, current_user) do
        if MyApp.Auth.can_access?(current_user, "users", :read) do
          Repo.get(User, id)
        else
          {:error, :unauthorized}
        end
      end

  2. **Database views** - Create views with WHERE clauses for different user levels:

      CREATE VIEW user_visible_posts AS
      SELECT * FROM posts WHERE user_id = current_user_id();

  3. **Query rewriting** - Modify queries in Elixir to include authorization constraints:

      defmodule MyApp.Repo do
        def all(queryable, current_user) do
          queryable
          |> apply_tenant_filter(current_user)
          |> Ecto.Repo.all()
        end
      end

  4. **Connection-level restrictions** - Use different database connections with different privileges

  ## Returns
    - `:unsupported` - Always returns unsupported

  """
  def add_authorizer(%EctoLibSql.State{conn_id: conn_id} = _state, pid \\ self()) do
    set_authorizer(conn_id, pid)
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
  Get the name of a parameter in a prepared statement by its index.

  Returns the parameter name for named parameters (`:name`, `@name`, `$name`),
  or `nil` for positional parameters (`?`).

  ## Parameters
    - state: The connection state
    - stmt_id: The statement ID returned from `prepare/2`
    - idx: Parameter index (1-based, following SQLite convention)

  ## Returns
    - `{:ok, name}` - Parameter has a name (e.g., `:id` returns `"id"`)
    - `{:ok, nil}` - Parameter is positional (`?`)
    - `{:error, reason}` - Error occurred

  ## Example

      # Named parameters
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "SELECT * FROM users WHERE id = :id AND name = :name")
      {:ok, param1} = EctoLibSql.Native.stmt_parameter_name(state, stmt_id, 1)
      # param1 = "id"
      {:ok, param2} = EctoLibSql.Native.stmt_parameter_name(state, stmt_id, 2)
      # param2 = "name"

      # Positional parameters
      {:ok, stmt_id} = EctoLibSql.Native.prepare(state, "SELECT * FROM users WHERE id = ?")
      {:ok, param1} = EctoLibSql.Native.stmt_parameter_name(state, stmt_id, 1)
      # param1 = nil

  ## Notes
    - Parameter indices are 1-based (first parameter is index 1)
    - Named parameters start with `:`, `@`, or `$` in SQL but the prefix is stripped in the returned name
    - Returns `nil` for positional `?` placeholders

  """
  def stmt_parameter_name(%EctoLibSql.State{conn_id: conn_id} = _state, stmt_id, idx)
      when is_binary(stmt_id) and is_integer(idx) and idx >= 1 do
    # The NIF returns Option<String> which becomes {:ok, "name"} or {:ok, nil} or {:error, reason}
    # But Rustler converts Some("name") to just "name", not {:ok, "name"}
    case statement_parameter_name(conn_id, stmt_id, idx) do
      name when is_binary(name) -> {:ok, name}
      nil -> {:ok, nil}
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
  Reset a prepared statement to its initial state for reuse.

  After executing a statement, you should reset it before binding new parameters
  and executing again. This allows efficient statement reuse without re-preparing
  the same SQL string repeatedly.

  **Performance Note**: Resetting and reusing statements is 10-15x faster than
  re-preparing the same SQL string. Always reset statements when executing the
  same query multiple times with different parameters.

  ## Parameters
    - state: The connection state with the prepared statement
    - stmt_id: The prepared statement ID

  ## Returns
    - `:ok` - Statement reset successfully
    - `{:error, reason}` - Reset failed

  ## Example

      {:ok, stmt_id} = EctoLibSql.prepare(state, "INSERT INTO logs (msg) VALUES (?)")

      for msg <- messages do
        EctoLibSql.execute_stmt(state, stmt_id, [msg])
        EctoLibSql.Native.reset_stmt(state, stmt_id)  # Reset for next iteration
      end

      EctoLibSql.close_stmt(state, stmt_id)

  """
  def reset_stmt(%EctoLibSql.State{conn_id: conn_id} = _state, stmt_id)
      when is_binary(conn_id) and is_binary(stmt_id) do
    reset_statement(conn_id, stmt_id)
  end

  @doc """
  Get column metadata for a prepared statement.

  Returns information about all columns that will be returned when the
  statement is executed. This includes column names, origin names, and declared types.

  ## Parameters
    - state: The connection state with the prepared statement
    - stmt_id: The prepared statement ID

  ## Returns
    - `{:ok, columns}` - List of tuples with `{name, origin_name, decl_type}`
    - `{:error, reason}` - Failed to get metadata

  ## Example

      {:ok, stmt_id} = EctoLibSql.prepare(state, "SELECT id, name, age FROM users")
      {:ok, columns} = EctoLibSql.Native.get_stmt_columns(state, stmt_id)
      # Returns:
      # [
      #   {"id", "id", "INTEGER"},
      #   {"name", "name", "TEXT"},
      #   {"age", "age", "INTEGER"}
      # ]

  ## Use Cases

    - **Type introspection**: Understand column types for dynamic queries
    - **Schema discovery**: Explore database structure without separate queries
    - **Better error messages**: Show column names and types in error output
    - **Type casting hints**: Help Ecto determine appropriate type conversions

  """
  def get_stmt_columns(%EctoLibSql.State{conn_id: conn_id} = _state, stmt_id)
      when is_binary(conn_id) and is_binary(stmt_id) do
    case get_statement_columns(conn_id, stmt_id) do
      {:ok, columns} -> {:ok, columns}
      result when is_list(result) -> {:ok, result}
      {:error, reason} -> {:error, reason}
      other -> {:error, "Unexpected response: #{inspect(other)}"}
    end
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

  # Encode parameters to handle complex Elixir types before passing to NIF.
  # The Rust NIF cannot serialize plain Elixir maps, so we convert them to JSON strings.
  @doc false
  defp encode_parameters(args) when is_list(args) do
    Enum.map(args, &encode_param/1)
  end

  defp encode_parameters(args), do: args

  @doc false
  # Only encode plain maps (not structs) to JSON.
  # Structs like DateTime, Decimal etc are handled in query.ex encode.
  defp encode_param(value) when is_map(value) and not is_struct(value) do
    Jason.encode!(value)
  end

  defp encode_param(value), do: value
end
