defmodule Ecto.Adapters.LibSql.Connection do
  @moduledoc """
  Implementation of Ecto.Adapters.SQL.Connection for LibSQL.

  This module handles SQL query generation and DDL operations for LibSQL/SQLite.
  It implements the `Ecto.Adapters.SQL.Connection` behaviour, translating Ecto's
  query structures into SQLite-compatible SQL.

  ## Key Responsibilities

  - Query generation (`all/1`, `update_all/1`, `delete_all/1`)
  - Insert/update/delete operations with RETURNING support
  - DDL generation (CREATE TABLE, ALTER TABLE, CREATE INDEX, etc.)
  - Constraint name extraction for error handling
  - Type mapping between Ecto and SQLite

  ## SQLite Compatibility

  This module ensures generated SQL is compatible with SQLite/LibSQL syntax,
  including handling of AUTOINCREMENT, ON CONFLICT clauses, and type affinities.
  """

  @behaviour Ecto.Adapters.SQL.Connection

  # Module attribute for parent query aliasing in CTEs and subqueries.
  @parent_as __MODULE__

  # Alias for CTE (Common Table Expression) handling.
  alias Ecto.Query.{ByExpr, QueryExpr, WithExpr}

  ## Query Generation

  @impl true
  def child_spec(opts) do
    DBConnection.child_spec(EctoLibSql, opts)
  end

  @impl true
  def prepare_execute(conn, name, sql, params, opts) do
    query = %EctoLibSql.Query{name: name, statement: sql}

    case DBConnection.prepare_execute(conn, query, params, opts) do
      {:ok, _query, result} -> {:ok, query, result}
      {:error, _} = error -> error
    end
  end

  @impl true
  def execute(conn, sql, params, opts) when is_binary(sql) do
    query = %EctoLibSql.Query{statement: sql}

    case DBConnection.execute(conn, query, params, opts) do
      {:ok, _query, result} -> {:ok, result}
      {:error, _} = error -> error
    end
  end

  def execute(conn, sql, params, opts) when is_list(sql) do
    execute(conn, IO.iodata_to_binary(sql), params, opts)
  end

  def execute(conn, %{} = query, params, opts) do
    case DBConnection.execute(conn, query, params, opts) do
      {:ok, _query, result} -> {:ok, result}
      {:error, _} = error -> error
    end
  end

  @impl true
  def stream(conn, sql, params, opts) do
    DBConnection.stream(conn, %EctoLibSql.Query{statement: sql}, params, opts)
  end

  @impl true
  @doc """
  Parse a SQLite error message and map it to a list of Ecto constraint tuples.

  Accepts an exception-like map containing a SQLite error `:message` and returns recognised constraint information such as unique, foreign_key or check constraints; returns an empty list when no known constraint pattern is found.

  ## Parameters

    - error: Map containing a `:message` string produced by SQLite.
    - _opts: Options (unused).

  ## Returns

    - A keyword list of constraint tuples, for example `[unique: "table_column_index"]`, `[foreign_key: :unknown]`, `[check: "constraint_name"]`, or `[]` when no constraint is recognised.
  """
  @spec to_constraints(%{message: String.t()}, Keyword.t()) :: Keyword.t()
  def to_constraints(%{message: message}, _opts) do
    cond do
      String.contains?(message, "UNIQUE constraint failed") ->
        [unique: extract_constraint_name(message)]

      String.contains?(message, "FOREIGN KEY constraint failed") ->
        [foreign_key: :unknown]

      String.contains?(message, "CHECK constraint failed") ->
        [check: extract_constraint_name(message)]

      String.contains?(message, "NOT NULL constraint failed") ->
        # NOT NULL is treated as a check constraint in Ecto
        [check: extract_constraint_name(message)]

      true ->
        []
    end
  end

  defp extract_constraint_name(message) do
    # Extract constraint name from SQLite error messages.
    #
    # SQLite only reports column names in constraint errors, not index names.
    # We reconstruct the index name following Ecto's naming convention:
    #   table_column1_column2_index
    #
    # Examples:
    #   "UNIQUE constraint failed: users.email" -> "users_email_index"
    #   "UNIQUE constraint failed: users.slug, users.parent_slug" -> "users_slug_parent_slug_index"
    #   "NOT NULL constraint failed: users.name" -> "users_name_index"
    #   "CHECK constraint failed: positive_age" -> "positive_age"
    #
    # First, try to extract the index name from enhanced error messages (if present)
    case Regex.run(~r/\(index: ([\w_]+)\)/, message) do
      [_, index_name] ->
        # Found enhanced error with actual index name
        index_name

      nil ->
        # No index name in message, reconstruct from column names
        case Regex.run(~r/constraint failed: (.+)$/, message) do
          [_, constraint_part] ->
            # Strip any trailing backticks that libSQL might add to error messages
            cleaned = constraint_part |> String.trim() |> String.trim_trailing("`")
            constraint_name_hack(cleaned)

          _ ->
            "unknown"
        end
    end
  end

  # Reconstruct index names from SQLite constraint error messages.
  # This follows Ecto's convention: table_column1_column2_index
  defp constraint_name_hack(constraint) do
    # Helper to clean backticks from identifiers (libSQL sometimes adds them)
    clean = fn s -> String.trim(s, "`") end

    if String.contains?(constraint, ", ") do
      # Multi-column constraint: "table.col1, table.col2" -> "table_col1_col2_index"
      [first | rest] = String.split(constraint, ", ")

      table_col = first |> clean.() |> String.replace(".", "_")

      cols =
        Enum.map(rest, fn col ->
          col |> clean.() |> String.split(".") |> List.last()
        end)

      [table_col | cols] |> Enum.concat(["index"]) |> Enum.join("_")
    else
      if String.contains?(constraint, ".") do
        # Single column: "table.column" -> "table_column_index"
        constraint
        |> clean.()
        |> String.split(".")
        |> Enum.concat(["index"])
        |> Enum.join("_")
      else
        # No table prefix (e.g., CHECK constraint name): return as-is
        clean.(constraint)
      end
    end
  end

  ## DDL Generation

  @impl true
  def ddl_logs(_), do: []

  @impl true
  def execute_ddl({command, %Ecto.Migration.Table{} = table, columns})
      when command in [:create, :create_if_not_exists] do
    table_name = quote_table(table.prefix, table.name)
    if_not_exists = if command == :create_if_not_exists, do: " IF NOT EXISTS", else: ""

    # Check if this is an R*Tree virtual table
    if table.options && Keyword.get(table.options, :rtree, false) do
      # Validate that no incompatible options are set with :rtree
      validate_rtree_options!(table.options)
      create_rtree_table(table_name, if_not_exists, columns)
    else
      # Standard table creation
      # Check if we have a composite primary key.
      composite_pk = composite_primary_key?(columns)

      column_definitions =
        Enum.map_join(columns, ", ", &column_definition(&1, composite_pk))

      {table_constraints, table_suffix} = table_options(table, columns)

      [
        "CREATE TABLE#{if_not_exists} #{table_name} (#{column_definitions}#{table_constraints})#{table_suffix}"
      ]
    end
  end

  def execute_ddl({:drop, %Ecto.Migration.Table{} = table, _}) do
    table_name = quote_table(table.prefix, table.name)
    ["DROP TABLE #{table_name}"]
  end

  def execute_ddl({:drop_if_exists, %Ecto.Migration.Table{} = table, _}) do
    table_name = quote_table(table.prefix, table.name)
    ["DROP TABLE IF EXISTS #{table_name}"]
  end

  def execute_ddl({:alter, %Ecto.Migration.Table{} = table, changes}) do
    table_name = quote_table(table.prefix, table.name)

    Enum.flat_map(changes, fn
      {:add, name, type, opts} ->
        # When altering, we're only adding one column, so no composite PK.
        column_def = column_definition({:add, name, type, opts}, false)
        ["ALTER TABLE #{table_name} ADD COLUMN #{column_def}"]

      {:modify, name, type, opts} ->
        # libSQL supports ALTER TABLE ALTER COLUMN for modifying column attributes.
        # This is a libSQL extension beyond standard SQLite.
        # Supported modifications: type affinity, NOT NULL, CHECK, DEFAULT, and REFERENCES.
        # Note: Existing rows are not revalidated; constraints only apply to new/updated data.
        column_def = alter_column_definition(name, type, opts)
        ["ALTER TABLE #{table_name} ALTER COLUMN #{column_def}"]

      {:remove, name, _type, _opts} ->
        # libSQL/SQLite 3.35.0+ supports DROP COLUMN.
        # Limitations: Cannot drop columns that are PRIMARY KEY, have UNIQUE constraint,
        # or are referenced by other parts of the schema.
        ["ALTER TABLE #{table_name} DROP COLUMN #{quote_name(name)}"]
    end)
  end

  def execute_ddl({:create, %Ecto.Migration.Index{} = index}) do
    fields = Enum.map_join(index.columns, ", ", &quote_name/1)
    table_name = quote_table(index.prefix, index.table)
    index_name = quote_name(index.name)
    unique = if index.unique, do: "UNIQUE ", else: ""
    where = if index.where, do: " WHERE #{index.where}", else: ""

    ["CREATE #{unique}INDEX #{index_name} ON #{table_name} (#{fields})#{where}"]
  end

  def execute_ddl({:create_if_not_exists, %Ecto.Migration.Index{} = index}) do
    fields = Enum.map_join(index.columns, ", ", &quote_name/1)
    table_name = quote_table(index.prefix, index.table)
    index_name = quote_name(index.name)
    unique = if index.unique, do: "UNIQUE ", else: ""
    where = if index.where, do: " WHERE #{index.where}", else: ""

    ["CREATE #{unique}INDEX IF NOT EXISTS #{index_name} ON #{table_name} (#{fields})#{where}"]
  end

  def execute_ddl({:drop, %Ecto.Migration.Index{} = index, _}) do
    index_name = quote_name(index.name)
    ["DROP INDEX #{index_name}"]
  end

  def execute_ddl({:drop_if_exists, %Ecto.Migration.Index{} = index, _}) do
    index_name = quote_name(index.name)
    ["DROP INDEX IF EXISTS #{index_name}"]
  end

  def execute_ddl({:rename, %Ecto.Migration.Table{} = table, old_name, new_name}) do
    table_name = quote_table(table.prefix, table.name)
    ["ALTER TABLE #{table_name} RENAME COLUMN #{quote_name(old_name)} TO #{quote_name(new_name)}"]
  end

  def execute_ddl(
        {:rename, %Ecto.Migration.Table{} = old_table, %Ecto.Migration.Table{} = new_table}
      ) do
    old_name = quote_table(old_table.prefix, old_table.name)
    new_name = quote_table(new_table.prefix, new_table.name)
    ["ALTER TABLE #{old_name} RENAME TO #{new_name}"]
  end

  def execute_ddl(string) when is_binary(string), do: [string]

  def execute_ddl(keyword) when is_list(keyword) do
    raise ArgumentError, "SQLite adapter does not support keyword lists in execute"
  end

  ## DDL Helpers

  defp alter_column_definition(name, %Ecto.Migration.Reference{} = ref, opts) do
    base_type = column_type(ref.type, [])
    references = reference_expr(ref)

    # For ALTER COLUMN, we construct: column_name TO column_name new_type [constraints] [references].
    "#{quote_name(name)} TO #{quote_name(name)} #{base_type}#{column_options(opts, false)}#{references}"
  end

  defp alter_column_definition(name, type, opts) do
    # For ALTER COLUMN, we construct: column_name TO column_name new_type [constraints].
    "#{quote_name(name)} TO #{quote_name(name)} #{column_type(type, opts)}#{column_options(opts, false)}"
  end

  defp composite_primary_key?(columns) do
    pk_count =
      Enum.count(columns, fn {:add, _name, _type, opts} ->
        Keyword.get(opts, :primary_key, false)
      end)

    pk_count > 1
  end

  defp column_definition({:add, name, %Ecto.Migration.Reference{} = ref, opts}, composite_pk) do
    base_type = column_type(ref.type, [])
    references = reference_expr(ref)
    "#{quote_name(name)} #{base_type}#{references}#{column_options(opts, composite_pk)}"
  end

  defp column_definition({:add, name, type, opts}, composite_pk) do
    "#{quote_name(name)} #{column_type(type, opts)}#{column_options(opts, composite_pk)}"
  end

  defp reference_expr(%Ecto.Migration.Reference{} = ref) do
    referenced_table = quote_name(ref.table)
    referenced_column = quote_name(ref.column || :id)

    " REFERENCES #{referenced_table}(#{referenced_column})" <>
      reference_on_delete(ref.on_delete) <>
      reference_on_update(ref.on_update)
  end

  defp reference_on_delete(nil), do: ""
  defp reference_on_delete(:nothing), do: ""
  defp reference_on_delete(:delete_all), do: " ON DELETE CASCADE"
  defp reference_on_delete(:nilify_all), do: " ON DELETE SET NULL"
  defp reference_on_delete(:restrict), do: " ON DELETE RESTRICT"

  defp reference_on_update(nil), do: ""
  defp reference_on_update(:nothing), do: ""
  defp reference_on_update(:update_all), do: " ON UPDATE CASCADE"
  defp reference_on_update(:nilify_all), do: " ON UPDATE SET NULL"
  defp reference_on_update(:restrict), do: " ON UPDATE RESTRICT"

  defp column_type(:id, _opts), do: "INTEGER"
  defp column_type(:binary_id, _opts), do: "TEXT"
  defp column_type(:uuid, _opts), do: "TEXT"
  defp column_type(:string, opts), do: "TEXT#{size_constraint(opts)}"
  defp column_type(:binary, opts), do: "BLOB#{size_constraint(opts)}"
  defp column_type(:map, _opts), do: "TEXT"
  defp column_type({:map, _}, _opts), do: "TEXT"
  defp column_type(:decimal, _opts), do: "DECIMAL"
  defp column_type(:float, _opts), do: "REAL"
  defp column_type(:integer, _opts), do: "INTEGER"
  defp column_type(:boolean, _opts), do: "INTEGER"
  defp column_type(:text, _opts), do: "TEXT"
  defp column_type(:date, _opts), do: "DATE"
  defp column_type(:time, _opts), do: "TIME"
  defp column_type(:time_usec, _opts), do: "TIME"
  defp column_type(:naive_datetime, _opts), do: "DATETIME"
  defp column_type(:naive_datetime_usec, _opts), do: "DATETIME"
  defp column_type(:utc_datetime, _opts), do: "DATETIME"
  defp column_type(:utc_datetime_usec, _opts), do: "DATETIME"

  defp column_type({:array, _}, _opts) do
    raise ArgumentError,
          "SQLite does not support array types. Use JSON or separate tables instead."
  end

  defp column_type(type, _opts) when is_atom(type), do: String.upcase(Atom.to_string(type))
  defp column_type(type, _opts), do: type

  defp size_constraint(opts) do
    case Keyword.get(opts, :size) do
      nil -> ""
      size -> "(#{size})"
    end
  end

  defp column_options(opts, composite_pk) do
    # Validate generated column constraints (SQLite disallows these combinations).
    if Keyword.has_key?(opts, :generated) do
      if Keyword.has_key?(opts, :default) do
        raise ArgumentError,
              "generated columns cannot have a DEFAULT value (SQLite constraint)"
      end

      if Keyword.get(opts, :primary_key) do
        raise ArgumentError,
              "generated columns cannot be part of a PRIMARY KEY (SQLite constraint)"
      end
    end

    default = column_default(Keyword.get(opts, :default))
    null = if Keyword.get(opts, :null) == false, do: " NOT NULL", else: ""

    # Only add PRIMARY KEY to individual column if it's not part of a composite key.
    pk =
      if Keyword.get(opts, :primary_key) && !composite_pk,
        do: " PRIMARY KEY",
        else: ""

    # Generated columns (SQLite 3.31+, libSQL 3.45.1+)
    generated =
      case Keyword.get(opts, :generated) do
        nil ->
          ""

        expr when is_binary(expr) ->
          stored = if Keyword.get(opts, :stored, false), do: " STORED", else: ""
          " GENERATED ALWAYS AS (#{expr})#{stored}"
      end

    "#{pk}#{null}#{default}#{generated}"
  end

  defp column_default(nil), do: ""
  defp column_default(true), do: " DEFAULT 1"
  defp column_default(false), do: " DEFAULT 0"
  defp column_default(value) when is_binary(value), do: " DEFAULT '#{escape_string(value)}'"
  defp column_default(value) when is_number(value), do: " DEFAULT #{value}"
  defp column_default({:fragment, expr}), do: " DEFAULT #{expr}"
  # Handle any other unexpected types (e.g., empty maps)
  defp column_default(_), do: ""

  defp table_options(table, columns) do
    # Validate mutually exclusive options (per libSQL specification)
    if table.options && Keyword.get(table.options, :random_rowid, false) do
      # RANDOM ROWID is mutually exclusive with WITHOUT ROWID
      if Keyword.get(table.options, :without_rowid, false) do
        raise ArgumentError,
              "RANDOM ROWID and WITHOUT ROWID are mutually exclusive options (per libSQL specification)"
      end

      # RANDOM ROWID is mutually exclusive with AUTOINCREMENT on any column
      autoincrement_column =
        Enum.find(columns, fn {:add, _name, _type, opts} ->
          Keyword.get(opts, :autoincrement, false)
        end)

      if autoincrement_column do
        {:add, col_name, _type, _opts} = autoincrement_column

        raise ArgumentError,
              "RANDOM ROWID and AUTOINCREMENT (on column #{inspect(col_name)}) are mutually exclusive options (per libSQL specification)"
      end
    end

    pk =
      Enum.filter(columns, fn {:add, _name, _type, opts} ->
        Keyword.get(opts, :primary_key, false)
      end)

    # Composite primary key constraint (goes inside CREATE TABLE parentheses)
    table_constraints =
      if length(pk) > 1 do
        pk_names = Enum.map_join(pk, ", ", fn {:add, name, _type, _opts} -> quote_name(name) end)
        ", PRIMARY KEY (#{pk_names})"
      else
        ""
      end

    # Table suffix options (go after closing parenthesis)
    suffixes = []

    suffixes =
      if table.options && Keyword.get(table.options, :random_rowid, false) do
        suffixes ++ [" RANDOM ROWID"]
      else
        suffixes
      end

    suffixes =
      if table.options && Keyword.get(table.options, :strict, false) do
        suffixes ++ [" STRICT"]
      else
        suffixes
      end

    table_suffix = Enum.join(suffixes)

    {table_constraints, table_suffix}
  end

  defp create_rtree_table(table_name, if_not_exists, columns) do
    # R*Tree virtual tables require specific column structure:
    # First column: integer primary key (id)
    # Remaining columns: coordinate pairs (min/max)

    # Extract column names for R*Tree
    rtree_columns =
      Enum.map(columns, fn {:add, name, _type, _opts} ->
        Atom.to_string(name)
      end)

    # Validate column structure
    validate_rtree_columns!(rtree_columns)

    # Build R*Tree column list: id, min1, max1, min2, max2, ...
    column_list = Enum.join(rtree_columns, ", ")

    [
      "CREATE VIRTUAL TABLE#{if_not_exists} #{table_name} USING rtree(#{column_list})"
    ]
  end

  defp validate_rtree_options!(options) do
    # R*Tree virtual tables are incompatible with standard table options
    # Check for any non-:rtree options that would be silently ignored
    incompatible_options =
      Keyword.keys(options)
      |> Enum.reject(&(&1 == :rtree))

    unless Enum.empty?(incompatible_options) do
      options_str = Enum.map_join(incompatible_options, ", ", &inspect/1)

      raise ArgumentError,
            "R*Tree virtual tables do not support standard table options. " <>
              "Found incompatible options: #{options_str}. " <>
              "R*Tree tables can only use the :rtree option."
    end

    :ok
  end

  defp validate_rtree_columns!(columns) do
    # R*Tree requires odd number of columns (3 to 11)
    # First column is ID, then min/max pairs
    num_columns = length(columns)

    cond do
      num_columns < 3 ->
        raise ArgumentError,
              "R*Tree tables require at least 3 columns (id + 1 dimension). Got #{num_columns} columns."

      num_columns > 11 ->
        raise ArgumentError,
              "R*Tree tables support maximum 11 columns (id + 5 dimensions). Got #{num_columns} columns."

      rem(num_columns, 2) == 0 ->
        raise ArgumentError,
              "R*Tree tables require odd number of columns (id + min/max pairs). Got #{num_columns} columns."

      true ->
        :ok
    end

    # Validate first column is 'id'
    [first_column | _rest] = columns

    unless first_column == "id" do
      raise ArgumentError,
            "R*Tree tables must have 'id' as the first column. Got '#{first_column}' instead."
    end

    :ok
  end

  ## Query Helpers

  defp quote_table(nil, name), do: quote_name(name)
  defp quote_table(prefix, name), do: quote_name(prefix) <> "." <> quote_name(name)

  defp quote_name(name) when is_atom(name), do: quote_name(Atom.to_string(name))

  defp quote_name(name) do
    if String.contains?(name, "\"") do
      raise ArgumentError, "bad table/column name #{inspect(name)}"
    end

    ~s("#{name}")
  end

  defp escape_string(value) do
    String.replace(value, "'", "''")
  end

  ## Table and column existence checks

  @impl true
  def table_exists_query(table) do
    {"SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1 LIMIT 1", [table]}
  end

  ## Query generation for CRUD operations

  @impl true
  def all(query, as_prefix \\ []) do
    sources = create_names(query, as_prefix)

    cte = cte(query, sources)
    from = "FROM #{from(query, sources)}"
    select = select(query, sources)
    join = join(query, sources)
    where = where(query, sources)
    group_by = group_by(query, sources)
    having = having(query, sources)
    window = window(query, sources)
    combination = combination(query, as_prefix)
    order_by = order_by(query, sources)
    limit = limit(query, sources)
    offset = offset(query, sources)
    lock = lock(query, sources)

    [
      cte,
      select,
      from,
      join,
      where,
      group_by,
      having,
      window,
      combination,
      order_by,
      limit,
      offset | lock
    ]
  end

  @impl true
  def update_all(query) do
    sources = create_names(query, [])
    {from, name} = get_source(query, sources, 0)

    fields = update_fields(query, sources)
    {join, wheres} = using_join(query, :update_all, "FROM", sources)
    where = where(%{query | wheres: wheres}, sources)

    ["UPDATE ", from, " AS ", name, " SET ", fields, join, where]
  end

  @impl true
  def delete_all(query) do
    sources = create_names(query, [])
    {from, name} = get_source(query, sources, 0)

    {join, wheres} = using_join(query, :delete_all, "USING", sources)
    where = where(%{query | wheres: wheres}, sources)

    ["DELETE FROM ", from, " AS ", name, join, where]
  end

  @impl true
  def insert(prefix, table, header, rows, on_conflict, returning, placeholders) do
    fields = intersperse_map(header, ", ", &quote_name/1)

    values =
      if rows == [] do
        [" DEFAULT VALUES"]
      else
        [" VALUES ", encode_values(rows)]
      end

    [
      "INSERT",
      insert_as(on_conflict),
      " INTO ",
      quote_table(prefix, table),
      " (",
      fields,
      ")",
      values,
      on_conflict(on_conflict, header, placeholders) | returning(returning)
    ]
  end

  defp encode_values(rows) do
    rows
    |> Enum.map(fn row ->
      ["(", intersperse_map(row, ", ", fn _ -> "?" end), ")"]
    end)
    |> Enum.intersperse(", ")
  end

  # Helper for INSERT OR ... syntax (not used for now, keeping for SQLite REPLACE compatibility)
  defp insert_as(_on_conflict), do: []

  # Generate ON CONFLICT clause for upsert operations
  # Pattern: {:raise, conflict_target, opts}
  defp on_conflict({:raise, _, _}, _header, _placeholders), do: []

  # Pattern: {:nothing, _, conflict_target}
  defp on_conflict({:nothing, _, [_ | _] = targets}, _header, _placeholders) do
    [" ON CONFLICT ", conflict_target(targets), "DO NOTHING"]
  end

  defp on_conflict({:nothing, _, []}, _header, _placeholders) do
    " ON CONFLICT DO NOTHING"
  end

  # Pattern: {:replace_all, _, conflict_target}
  defp on_conflict({:replace_all, _, {:constraint, _}}, _header, _placeholders) do
    raise ArgumentError, "Upsert in LibSQL does not support ON CONSTRAINT"
  end

  defp on_conflict({:replace_all, _, []}, _header, _placeholders) do
    raise ArgumentError, "Upsert in LibSQL requires :conflict_target"
  end

  defp on_conflict({:replace_all, _, targets}, header, _placeholders) when is_list(targets) do
    [" ON CONFLICT ", conflict_target(targets), "DO ", replace(header)]
  end

  # Pattern: {fields_list, _, conflict_target} - for custom field replacement
  defp on_conflict({fields, _, [_ | _] = targets}, _header, _placeholders)
       when is_list(fields) do
    [" ON CONFLICT ", conflict_target(targets), "DO ", replace(fields)]
  end

  # Pattern: {%Ecto.Query{}, _, conflict_target} - for query-based updates
  defp on_conflict({%Ecto.Query{} = _query, _, []}, _header, _placeholders) do
    raise ArgumentError, "Upsert in LibSQL requires :conflict_target for query-based on_conflict"
  end

  defp on_conflict({%Ecto.Query{} = query, _, targets}, _header, _placeholders) do
    [" ON CONFLICT ", conflict_target(targets), "DO ", update_all_for_on_conflict(query)]
  end

  # Fallback for other on_conflict values (including plain :raise, etc.)
  defp on_conflict(_on_conflict, _header, _placeholders), do: []

  defp conflict_target([]), do: []

  defp conflict_target(targets) do
    ["(", intersperse_map(targets, ", ", &quote_name/1), ") "]
  end

  defp replace(fields) do
    ["UPDATE SET " | intersperse_map(fields, ", ", &replace_field/1)]
  end

  defp replace_field(field) do
    quoted = quote_name(field)
    [quoted, " = ", "excluded.", quoted]
  end

  # Generates UPDATE SET clause from a query for on_conflict
  defp update_all_for_on_conflict(%Ecto.Query{} = query) do
    sources = create_names(query, [])
    fields = update_fields(query, sources)
    ["UPDATE SET " | fields]
  end

  @impl true
  def update(prefix, table, fields, filters, returning) do
    {fields, count} =
      intersperse_reduce(fields, ", ", 1, fn field, acc ->
        {[quote_name(field), " = ?"], acc + 1}
      end)

    {filters, _count} =
      intersperse_reduce(filters, " AND ", count, fn {field, _value}, acc ->
        {[quote_name(field), " = ?"], acc + 1}
      end)

    [
      "UPDATE ",
      quote_table(prefix, table),
      " SET ",
      fields,
      " WHERE ",
      filters | returning(returning)
    ]
  end

  @impl true
  def delete(prefix, table, filters, returning) do
    {filters, _} =
      intersperse_reduce(filters, " AND ", 1, fn {field, _value}, acc ->
        {[quote_name(field), " = ?"], acc + 1}
      end)

    ["DELETE FROM ", quote_table(prefix, table), " WHERE ", filters | returning(returning)]
  end

  @impl true
  def explain_query(conn, query, params, opts) do
    # The query parameter is the prepared SQL string generated by Ecto
    # Prepend "EXPLAIN QUERY PLAN" to get the optimiser plan
    sql = IO.iodata_to_binary(["EXPLAIN QUERY PLAN " | query])

    # EXPLAIN QUERY PLAN returns rows, so use query() path not execute()
    case query(conn, sql, params, opts) do
      {:ok, result} ->
        # Convert result to list of maps for Ecto's explain consumption
        # Return {:ok, maps} - Ecto.Multi requires this format
        maps =
          Enum.map(result.rows, fn row ->
            Enum.zip(result.columns, row) |> Enum.into(%{})
          end)

        {:ok, maps}

      error ->
        error
    end
  end

  @impl true
  def query(conn, sql, params, opts) do
    execute(conn, sql, params, opts)
  end

  @impl true
  def query_many(conn, sql, params, opts) do
    # SQLite doesn't support multiple queries in a single call
    # For now, split and execute sequentially
    queries = String.split(sql, ";", trim: true)

    results =
      Enum.map(queries, fn q ->
        case execute(conn, String.trim(q), params, opts) do
          {:ok, result} -> result
          {:error, _} = error -> error
        end
      end)

    {:ok, results}
  end

  ## Helpers for query generation

  defp create_names(%{sources: sources}, as_prefix) do
    List.to_tuple(create_names(sources, 0, tuple_size(sources), as_prefix))
  end

  defp create_names(sources, pos, limit, as_prefix) when pos < limit do
    [create_name(sources, pos, as_prefix) | create_names(sources, pos + 1, limit, as_prefix)]
  end

  defp create_names(_sources, pos, pos, _as_prefix) do
    []
  end

  defp create_name(sources, pos, as_prefix) do
    case elem(sources, pos) do
      {:fragment, _, _} ->
        {nil, as_prefix ++ [?f] ++ Integer.to_charlist(pos), nil}

      %Ecto.SubQuery{query: query} ->
        {nil, as_prefix ++ [?s] ++ Integer.to_charlist(pos), query}

      {table, schema, _} ->
        {quote_table(nil, table), as_prefix ++ [?s] ++ Integer.to_charlist(pos), schema}
    end
  end

  defp from(%{from: %{source: _source}} = query, sources) do
    {from, name} = get_source(query, sources, 0)
    [from, " AS ", name]
  end

  defp get_source(_query, sources, ix) do
    {source, name, _schema} = elem(sources, ix)
    {source, name}
  end

  defp quote_qualified_name(_source, sources, ix) do
    {_, name, _} = elem(sources, ix)
    name
  end

  defp select(%{select: select} = query, sources) do
    ["SELECT ", select_fields(select, sources, query), ?\s]
  end

  defp select_fields(%{fields: fields}, sources, query) do
    intersperse_map(fields, ", ", fn
      {:&, _, [idx]} ->
        {_source, _name, schema} = elem(sources, idx)
        qualifier = quote_qualified_name(nil, sources, idx)

        if schema do
          Enum.map_join(schema.__schema__(:fields), ", ", &[qualifier, ?., quote_name(&1)])
        else
          [qualifier, ?., ?*]
        end

      {key, _value} when is_atom(key) ->
        [quote_name(key)]

      value ->
        expr(value, sources, query)
    end)
  end

  defp join(%{joins: []}, _sources), do: []

  defp join(%{joins: joins} = query, sources) do
    [
      ?\s
      | intersperse_map(joins, ?\s, fn
          %Ecto.Query.JoinExpr{on: %{expr: expr}, qual: qual, ix: ix, source: _source} ->
            {join, name} = get_source(query, sources, ix)
            [join_qual(qual), join, " AS ", name, " ON ", expr(expr, sources, query)]
        end)
    ]
  end

  defp join_qual(:inner), do: "INNER JOIN "
  defp join_qual(:left), do: "LEFT OUTER JOIN "
  defp join_qual(:right), do: "RIGHT OUTER JOIN "
  defp join_qual(:full), do: "FULL OUTER JOIN "
  defp join_qual(:cross), do: "CROSS JOIN "

  defp where(%{wheres: wheres} = query, sources) do
    boolean(" WHERE ", wheres, sources, query)
  end

  defp having(%{havings: havings} = query, sources) do
    boolean(" HAVING ", havings, sources, query)
  end

  defp group_by(%{group_bys: []}, _sources), do: []

  defp group_by(%{group_bys: group_bys} = query, sources) do
    [
      " GROUP BY "
      | Enum.map_intersperse(group_bys, ", ", fn
          %ByExpr{expr: expr} ->
            Enum.map_intersperse(expr, ", ", &expr(&1, sources, query))
        end)
    ]
  end

  defp window(%{windows: []}, _sources), do: []

  defp window(%{windows: windows} = query, sources) do
    intersperse_map(windows, ", ", fn {name, %{expr: kw}} ->
      [quote_name(name), " AS ", window_exprs(kw, sources, query)]
    end)
  end

  defp window_exprs(kw, sources, query) do
    partition =
      if kw[:partition_by] != [],
        do: window_partition_by(kw, sources, query),
        else: []

    [?(, partition, window_order_by(kw, sources, query), ?)]
  end

  defp window_partition_by(kw, sources, query) do
    [" PARTITION BY " | intersperse_map(kw[:partition_by], ", ", &expr(&1, sources, query))]
  end

  defp window_order_by(kw, sources, query) do
    [" ORDER BY " | intersperse_map(kw[:order_by], ", ", &order_by_expr(&1, sources, query))]
  end

  defp order_by(%{order_bys: []}, _sources), do: []

  defp order_by(%{order_bys: order_bys} = query, sources) do
    [
      " ORDER BY "
      | intersperse_map(order_bys, ", ", fn %{expr: expr} ->
          intersperse_map(expr, ", ", &order_by_expr(&1, sources, query))
        end)
    ]
  end

  defp order_by_expr({dir, expr}, sources, query) do
    str = expr(expr, sources, query)

    case dir do
      :asc -> str
      :desc -> [str, " DESC"]
    end
  end

  defp limit(%{limit: nil}, _sources), do: []

  defp limit(%{limit: %{expr: expr}} = query, sources) do
    [" LIMIT ", expr(expr, sources, query)]
  end

  defp offset(%{offset: nil}, _sources), do: []

  defp offset(%{offset: %{expr: expr}} = query, sources) do
    [" OFFSET ", expr(expr, sources, query)]
  end

  defp lock(_query, _sources), do: []

  ## CTE (Common Table Expression) support

  # Generate WITH clause for CTEs.
  defp cte(%{with_ctes: %WithExpr{queries: [_ | _]}} = query, sources) do
    %{with_ctes: with_expr} = query
    recursive_opt = if with_expr.recursive, do: "RECURSIVE ", else: ""
    ctes = Enum.map_intersperse(with_expr.queries, ", ", &cte_expr(&1, sources, query))
    ["WITH ", recursive_opt, ctes, " "]
  end

  defp cte(%{with_ctes: _}, _sources), do: []

  # Generate a single CTE definition: name AS (query).
  defp cte_expr({name, opts, cte}, sources, query) do
    operation_opt = Map.get(opts, :operation)
    [quote_name(name), " AS ", cte_query(cte, sources, query, operation_opt)]
  end

  # Generate the query part of a CTE.
  defp cte_query(query, sources, parent_query, nil) do
    cte_query(query, sources, parent_query, :all)
  end

  defp cte_query(%Ecto.Query{} = query, sources, parent_query, :update_all) do
    query = put_in(query.aliases[@parent_as], {parent_query, sources})
    ["(", update_all(query), ")"]
  end

  defp cte_query(%Ecto.Query{} = query, sources, parent_query, :delete_all) do
    query = put_in(query.aliases[@parent_as], {parent_query, sources})
    ["(", delete_all(query), ")"]
  end

  defp cte_query(%Ecto.Query{} = query, sources, parent_query, :all) do
    query = put_in(query.aliases[@parent_as], {parent_query, sources})
    ["(", all(query, subquery_as_prefix(sources)), ")"]
  end

  defp cte_query(%QueryExpr{expr: expr}, sources, query, _operation) do
    expr(expr, sources, query)
  end

  # Generate prefix for subquery aliases.
  defp subquery_as_prefix(sources) do
    {_, name, _} = :erlang.element(tuple_size(sources), sources)
    [?s] ++ name
  end

  defp boolean(_name, [], _sources, _query), do: []

  defp boolean(name, [%{expr: expr, op: op} | query_exprs], sources, query) do
    reduced =
      Enum.reduce(query_exprs, {op, paren_expr(expr, sources, query)}, fn
        %{expr: expr, op: op}, {op, acc} ->
          {op, [acc, operator_to_boolean(op), paren_expr(expr, sources, query)]}

        %{expr: expr, op: op}, {_, acc} ->
          {op, [?(, acc, ?), operator_to_boolean(op), paren_expr(expr, sources, query)]}
      end)

    [name, elem(reduced, 1)]
  end

  defp operator_to_boolean(:and), do: " AND "
  defp operator_to_boolean(:or), do: " OR "

  defp paren_expr(expr, sources, query) do
    [?(, expr(expr, sources, query), ?)]
  end

  # Parameter placeholder
  defp expr({:^, [], [_ix]}, _sources, _query) do
    ~c"?"
  end

  # Qualified field reference: s0.field
  defp expr({{:., _, [{:&, _, [idx]}, field]}, _, []}, sources, _query)
       when is_atom(field) or is_binary(field) do
    {_, name} = get_source(nil, sources, idx)
    [name, ?. | quote_name(field)]
  end

  # Table reference: &0 -> s0
  defp expr({:&, _, [idx]}, sources, _query) do
    {_, name} = get_source(nil, sources, idx)
    name
  end

  # Literals
  defp expr({:constant, _, [literal]}, _sources, _query) when is_binary(literal) do
    [?', escape_string(literal), ?']
  end

  defp expr({:constant, _, [literal]}, _sources, _query) when is_number(literal) do
    to_string(literal)
  end

  defp expr({:constant, _, [true]}, _sources, _query), do: "1"
  defp expr({:constant, _, [false]}, _sources, _query), do: "0"
  defp expr({:constant, _, [nil]}, _sources, _query), do: "NULL"

  # Boolean operations
  defp expr({:is_nil, _, [arg]}, sources, query) do
    [expr(arg, sources, query) | " IS NULL"]
  end

  defp expr({:not, _, [arg]}, sources, query) do
    ["NOT (", expr(arg, sources, query), ?)]
  end

  # Comparison operations
  defp expr({:==, _, [left, right]}, sources, query) do
    [expr(left, sources, query), " = ", expr(right, sources, query)]
  end

  defp expr({:!=, _, [left, right]}, sources, query) do
    [expr(left, sources, query), " != ", expr(right, sources, query)]
  end

  defp expr({:<, _, [left, right]}, sources, query) do
    [expr(left, sources, query), " < ", expr(right, sources, query)]
  end

  defp expr({:>, _, [left, right]}, sources, query) do
    [expr(left, sources, query), " > ", expr(right, sources, query)]
  end

  defp expr({:<=, _, [left, right]}, sources, query) do
    [expr(left, sources, query), " <= ", expr(right, sources, query)]
  end

  defp expr({:>=, _, [left, right]}, sources, query) do
    [expr(left, sources, query), " >= ", expr(right, sources, query)]
  end

  # Boolean logic
  defp expr({:and, _, [left, right]}, sources, query) do
    [?(, expr(left, sources, query), " AND ", expr(right, sources, query), ?)]
  end

  defp expr({:or, _, [left, right]}, sources, query) do
    [?(, expr(left, sources, query), " OR ", expr(right, sources, query), ?)]
  end

  # IN clause
  defp expr({:in, _, [left, right]}, sources, query) when is_list(right) do
    args = Enum.map_intersperse(right, ?,, &expr(&1, sources, query))
    [expr(left, sources, query), " IN (", args, ?)]
  end

  defp expr({:in, _, [left, {:^, _, [_, length]}]}, sources, query) do
    args = Enum.intersperse(List.duplicate(??, length), ?,)
    [expr(left, sources, query), " IN (", args, ?)]
  end

  # LIKE
  defp expr({:like, _, [left, right]}, sources, query) do
    [expr(left, sources, query), " LIKE ", expr(right, sources, query)]
  end

  # Count
  defp expr({:count, _, []}, _sources, _query), do: "count(*)"

  defp expr({:count, _, [arg]}, sources, query) do
    ["count(", expr(arg, sources, query), ?)]
  end

  # Aggregate functions
  defp expr({:sum, _, [arg]}, sources, query) do
    ["sum(", expr(arg, sources, query), ?)]
  end

  defp expr({:avg, _, [arg]}, sources, query) do
    ["avg(", expr(arg, sources, query), ?)]
  end

  defp expr({:min, _, [arg]}, sources, query) do
    ["min(", expr(arg, sources, query), ?)]
  end

  defp expr({:max, _, [arg]}, sources, query) do
    ["max(", expr(arg, sources, query), ?)]
  end

  # Fragment for raw SQL
  defp expr({:fragment, _, parts}, sources, query) do
    Enum.map(parts, fn
      {:raw, part} -> part
      {:expr, e} -> expr(e, sources, query)
    end)
  end

  # Selected as (for query aliases)
  defp expr({:selected_as, _, [name]}, _sources, _query) do
    quote_name(name)
  end

  # Type casting
  defp expr({:type, _, [arg, _type]}, sources, query) do
    expr(arg, sources, query)
  end

  # Literal values (numbers, strings, etc.)
  defp expr(literal, _sources, _query) when is_number(literal) do
    to_string(literal)
  end

  defp expr(literal, _sources, _query) when is_binary(literal) do
    [?', escape_string(literal), ?']
  end

  defp expr(true, _sources, _query), do: "1"
  defp expr(false, _sources, _query), do: "0"
  defp expr(nil, _sources, _query), do: "NULL"

  # Default fallback for unsupported expressions
  defp expr(_expr, _sources, _query) do
    "?"
  end

  defp combination(%{combinations: []}, _as_prefix), do: []

  defp combination(%{combinations: combinations}, as_prefix) do
    Enum.map(combinations, fn {type, query} ->
      [combination_type(type), all(query, as_prefix)]
    end)
  end

  defp combination_type(:union), do: " UNION "
  defp combination_type(:union_all), do: " UNION ALL "
  defp combination_type(:except), do: " EXCEPT "
  defp combination_type(:except_all), do: " EXCEPT ALL "
  defp combination_type(:intersect), do: " INTERSECT "
  defp combination_type(:intersect_all), do: " INTERSECT ALL "

  defp update_fields(%{updates: updates} = query, sources) do
    for(
      %{expr: expr} <- updates,
      {op, kw} <- expr,
      {key, value} <- kw,
      do: update_op(op, key, value, sources, query)
    )
    |> Enum.intersperse(", ")
  end

  defp update_op(:set, key, value, sources, query) do
    [quote_name(key), " = ", expr(value, sources, query)]
  end

  defp update_op(:inc, key, value, sources, query) do
    [quote_name(key), " = ", quote_name(key), " + ", expr(value, sources, query)]
  end

  defp using_join(%{joins: []} = query, _kind, _prefix, _sources), do: {[], query.wheres}

  defp using_join(%{joins: _joins} = query, _kind, _prefix, _sources) do
    {[], query.wheres}
  end

  defp returning([]), do: []

  defp returning(returning) do
    [" RETURNING " | intersperse_map(returning, ?,, &quote_name/1)]
  end

  defp intersperse_map(list, separator, mapper) do
    intersperse_map(list, separator, mapper, [])
  end

  defp intersperse_map([elem], _separator, mapper, acc) do
    [acc | mapper.(elem)]
  end

  defp intersperse_map([elem | rest], separator, mapper, acc) do
    intersperse_map(rest, separator, mapper, [acc, mapper.(elem), separator])
  end

  defp intersperse_map([], _separator, _mapper, []) do
    []
  end

  defp intersperse_reduce(list, separator, initial, reducer) do
    intersperse_reduce(list, separator, initial, [], reducer)
  end

  defp intersperse_reduce([elem], _separator, count, acc, reducer) do
    {content, count} = reducer.(elem, count)
    {[acc | content], count}
  end

  defp intersperse_reduce([elem | rest], separator, count, acc, reducer) do
    {content, count} = reducer.(elem, count)
    intersperse_reduce(rest, separator, count, [acc, content, separator], reducer)
  end

  defp intersperse_reduce([], _separator, count, [], _reducer) do
    {[], count}
  end
end
