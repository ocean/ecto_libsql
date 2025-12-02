defmodule EctoLibSql.Pragma do
  @moduledoc """
  Helper functions for executing SQLite PRAGMA statements.

  PRAGMA statements are SQLite's configuration mechanism. This module provides
  convenient wrapper functions for common PRAGMA operations.

  ## Common Use Cases

  - Enable foreign key constraints
  - Set journal mode (WAL for better concurrency)
  - Configure synchronisation level
  - Query database configuration

  ## Examples

      # Enable foreign keys
      {:ok, state} = EctoLibSql.connect(database: "app.db")
      :ok = EctoLibSql.Pragma.enable_foreign_keys(state)

      # Set WAL mode
      {:ok, _result} = EctoLibSql.Pragma.set_journal_mode(state, :wal)

      # Check current foreign keys setting
      {:ok, result} = EctoLibSql.Pragma.foreign_keys(state)
      # result.rows => [[1]] if enabled, [[0]] if disabled

  ## Integration with Ecto

  PRAGMA statements are often executed during repository initialisation:

      # In your Repo module
      def init(_type, config) do
        {:ok, Keyword.put(config, :after_connect, &set_pragmas/1)}
      end

      defp set_pragmas(conn) do
        with {:ok, state} <- DBConnection.get_connection_state(conn),
             :ok <- EctoLibSql.Pragma.enable_foreign_keys(state),
             {:ok, _} <- EctoLibSql.Pragma.set_journal_mode(state, :wal) do
          :ok
        end
      end

  """

  alias EctoLibSql.{Native, State}

  @doc """
  Execute a raw PRAGMA statement.

  This is the low-level function that all other PRAGMA helpers use.

  ## Parameters

    - state: Connection state
    - pragma_stmt: The complete PRAGMA statement (e.g., "PRAGMA foreign_keys = ON")

  ## Returns

    - `{:ok, result}` with query result
    - `{:error, reason}` on failure

  ## Examples

      {:ok, result} = EctoLibSql.Pragma.query(state, "PRAGMA foreign_keys = ON")
      {:ok, result} = EctoLibSql.Pragma.query(state, "PRAGMA table_info(users)")

  """
  def query(%State{conn_id: conn_id} = _state, pragma_stmt) when is_binary(pragma_stmt) do
    case Native.pragma_query(conn_id, pragma_stmt) do
      # Handle map response from NIF (standard format)
      %{"columns" => columns, "rows" => rows, "num_rows" => num_rows} ->
        result = %EctoLibSql.Result{
          command: :pragma,
          columns: columns,
          rows: rows,
          num_rows: num_rows
        }

        {:ok, result}

      # Handle tuple response (alternative format)
      {columns, rows} when is_list(columns) and is_list(rows) ->
        result = %EctoLibSql.Result{
          command: :pragma,
          columns: columns,
          rows: rows,
          num_rows: length(rows)
        }

        {:ok, result}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_response, other}}
    end
  end

  @doc """
  Enable foreign key constraints.

  By default, SQLite does not enforce foreign key constraints. This function
  enables them for the current connection.

  ## Parameters

    - state: Connection state

  ## Returns

    - `:ok` on success
    - `{:error, reason}` on failure

  ## Examples

      :ok = EctoLibSql.Pragma.enable_foreign_keys(state)

  ## Notes

  This setting is per-connection and must be set each time you connect.
  Consider setting it in your Repo's `after_connect` callback.

  """
  def enable_foreign_keys(%State{} = state) do
    case query(state, "PRAGMA foreign_keys = ON") do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Disable foreign key constraints.

  ## Parameters

    - state: Connection state

  ## Returns

    - `:ok` on success
    - `{:error, reason}` on failure

  ## Examples

      :ok = EctoLibSql.Pragma.disable_foreign_keys(state)

  """
  def disable_foreign_keys(%State{} = state) do
    case query(state, "PRAGMA foreign_keys = OFF") do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Query the current foreign keys setting.

  ## Parameters

    - state: Connection state

  ## Returns

    - `{:ok, result}` where result.rows is [[1]] if enabled, [[0]] if disabled
    - `{:error, reason}` on failure

  ## Examples

      {:ok, result} = EctoLibSql.Pragma.foreign_keys(state)
      enabled? = result.rows == [[1]]

  """
  def foreign_keys(%State{} = state) do
    query(state, "PRAGMA foreign_keys")
  end

  @doc """
  Set the journal mode.

  SQLite supports several journal modes:
  - `:delete` - Default mode, deletes journal file after transaction
  - `:wal` - Write-Ahead Logging, better for concurrent access
  - `:memory` - Keep journal in memory
  - `:persist` - Keep journal file but zero it out
  - `:truncate` - Truncate journal file instead of deleting
  - `:off` - No journal (dangerous, not recommended)

  ## Parameters

    - state: Connection state
    - mode: One of `:delete`, `:wal`, `:memory`, `:persist`, `:truncate`, `:off`

  ## Returns

    - `{:ok, result}` with the new journal mode
    - `{:error, reason}` on failure

  ## Examples

      {:ok, result} = EctoLibSql.Pragma.set_journal_mode(state, :wal)
      # result.rows => [["wal"]]

  ## Recommendations

  For applications with concurrent reads/writes, use `:wal` mode:

      EctoLibSql.Pragma.set_journal_mode(state, :wal)

  """
  def set_journal_mode(%State{} = state, mode)
      when mode in [:delete, :wal, :memory, :persist, :truncate, :off] do
    mode_str = mode |> Atom.to_string() |> String.upcase()
    query(state, "PRAGMA journal_mode = #{mode_str}")
  end

  @doc """
  Query the current journal mode.

  ## Parameters

    - state: Connection state

  ## Returns

    - `{:ok, result}` where result.rows contains the current mode
    - `{:error, reason}` on failure

  ## Examples

      {:ok, result} = EctoLibSql.Pragma.journal_mode(state)
      # result.rows => [["wal"]] or [["delete"]], etc.

  """
  def journal_mode(%State{} = state) do
    query(state, "PRAGMA journal_mode")
  end

  @doc """
  Set the synchronous mode.

  Controls how often SQLite syncs data to disk:
  - `:off` (0) - No syncing (fastest, risk of corruption)
  - `:normal` (1) - Sync at critical moments (good balance)
  - `:full` (2) - Sync after every write (safest, slowest)
  - `:extra` (3) - Even more syncing than FULL

  ## Parameters

    - state: Connection state
    - level: One of `:off`, `:normal`, `:full`, `:extra`, or integer 0-3

  ## Returns

    - `{:ok, result}` on success
    - `{:error, reason}` on failure

  ## Examples

      {:ok, _} = EctoLibSql.Pragma.set_synchronous(state, :normal)

  ## Recommendations

  - Production: `:normal` or `:full` (with WAL mode, `:normal` is usually sufficient)
  - Development: `:normal`
  - Never use `:off` in production

  """
  def set_synchronous(%State{} = state, level) when level in [:off, :normal, :full, :extra] do
    level_str = level |> Atom.to_string() |> String.upcase()
    query(state, "PRAGMA synchronous = #{level_str}")
  end

  def set_synchronous(%State{} = state, level)
      when is_integer(level) and level >= 0 and level <= 3 do
    query(state, "PRAGMA synchronous = #{level}")
  end

  @doc """
  Query the current synchronous setting.

  ## Parameters

    - state: Connection state

  ## Returns

    - `{:ok, result}` where result.rows contains the current level (0-3)
    - `{:error, reason}` on failure

  ## Examples

      {:ok, result} = EctoLibSql.Pragma.synchronous(state)
      # result.rows => [[2]] for FULL, [[1]] for NORMAL, etc.

  """
  def synchronous(%State{} = state) do
    query(state, "PRAGMA synchronous")
  end

  @doc """
  Get information about a table's columns.

  This is useful for introspection and debugging.

  ## Parameters

    - state: Connection state
    - table_name: Name of the table (string or atom)

  ## Returns

    - `{:ok, result}` with column information
    - `{:error, reason}` on failure

  ## Examples

      {:ok, result} = EctoLibSql.Pragma.table_info(state, :users)
      # result.rows => [
      #   [0, "id", "INTEGER", 0, nil, 1],
      #   [1, "name", "TEXT", 1, nil, 0],
      #   ...
      # ]

  Each row contains: [cid, name, type, notnull, dflt_value, pk]

  """
  def table_info(%State{} = state, table_name) when is_atom(table_name) do
    table_info(state, Atom.to_string(table_name))
  end

  def table_info(%State{} = state, table_name) when is_binary(table_name) do
    query(state, "PRAGMA table_info(#{table_name})")
  end

  @doc """
  List all tables in the database.

  ## Parameters

    - state: Connection state

  ## Returns

    - `{:ok, result}` with table names
    - `{:error, reason}` on failure

  ## Examples

      {:ok, result} = EctoLibSql.Pragma.table_list(state)
      # result.rows => [["users"], ["posts"], ...]

  """
  def table_list(%State{} = state) do
    query(state, "PRAGMA table_list")
  end

  @doc """
  Get the user version number.

  SQLite databases can store a user version number (typically used for schema versioning).

  ## Parameters

    - state: Connection state

  ## Returns

    - `{:ok, result}` where result.rows contains the version number
    - `{:error, reason}` on failure

  ## Examples

      {:ok, result} = EctoLibSql.Pragma.user_version(state)
      # result.rows => [[42]]

  """
  def user_version(%State{} = state) do
    query(state, "PRAGMA user_version")
  end

  @doc """
  Set the user version number.

  ## Parameters

    - state: Connection state
    - version: Integer version number

  ## Returns

    - `{:ok, result}` on success
    - `{:error, reason}` on failure

  ## Examples

      {:ok, _} = EctoLibSql.Pragma.set_user_version(state, 42)

  """
  def set_user_version(%State{} = state, version) when is_integer(version) do
    query(state, "PRAGMA user_version = #{version}")
  end
end
