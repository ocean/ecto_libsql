defmodule Ecto.Adapters.LibSqlEx.Connection do
  @moduledoc false

  @behaviour Ecto.Adapters.SQL.Connection

  ## Query Generation

  @impl true
  def child_spec(opts) do
    DBConnection.child_spec(LibSqlEx, opts)
  end

  @impl true
  def prepare_execute(conn, name, sql, params, opts) do
    query = %LibSqlEx.Query{name: name, statement: sql}

    case DBConnection.prepare_execute(conn, query, params, opts) do
      {:ok, _query, result} -> {:ok, query, result}
      {:error, _} = error -> error
    end
  end

  @impl true
  def execute(conn, sql, params, opts) when is_binary(sql) do
    query = %LibSqlEx.Query{statement: sql}

    case DBConnection.execute(conn, query, params, opts) do
      {:ok, _query, result} -> {:ok, result}
      {:error, _} = error -> error
    end
  end

  def execute(conn, %{} = query, params, opts) do
    case DBConnection.execute(conn, query, params, opts) do
      {:ok, _query, result} -> {:ok, result}
      {:error, _} = error -> error
    end
  end

  @impl true
  def stream(conn, sql, params, opts) do
    DBConnection.stream(conn, %LibSqlEx.Query{statement: sql}, params, opts)
  end

  @impl true
  def to_constraints(%{message: message}, _opts) do
    case message do
      "UNIQUE constraint failed: " <> _ ->
        [unique: extract_constraint_name(message)]

      "FOREIGN KEY constraint failed" ->
        [foreign_key: :unknown]

      "CHECK constraint failed: " <> _ ->
        [check: extract_constraint_name(message)]

      _ ->
        []
    end
  end

  defp extract_constraint_name(message) do
    # Extract constraint name from SQLite error messages
    case Regex.run(~r/constraint failed: (\w+)/, message) do
      [_, name] -> String.to_atom(name)
      _ -> :unknown
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

    column_definitions = Enum.map_join(columns, ", ", &column_definition/1)
    table_options = table_options(table, columns)

    [
      "CREATE TABLE#{if_not_exists} #{table_name} (#{column_definitions}#{table_options})"
    ]
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
        column_def = column_definition({:add, name, type, opts})
        ["ALTER TABLE #{table_name} ADD COLUMN #{column_def}"]

      {:modify, _name, _type, _opts} ->
        raise ArgumentError,
              "ALTER COLUMN is not supported by SQLite. " <>
                "You need to recreate the table instead."

      {:remove, name, _type, _opts} ->
        # SQLite doesn't support DROP COLUMN directly (before 3.35.0)
        # For now, raise an error suggesting table recreation
        raise ArgumentError,
              "DROP COLUMN for #{name} is not supported by older SQLite versions. " <>
                "You need to recreate the table instead."
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

  defp column_definition({:add, name, type, opts}) do
    "#{quote_name(name)} #{column_type(type, opts)}#{column_options(opts)}"
  end

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

  defp column_type(type, _opts) when is_atom(type), do: Atom.to_string(type) |> String.upcase()
  defp column_type(type, _opts), do: type

  defp size_constraint(opts) do
    case Keyword.get(opts, :size) do
      nil -> ""
      size -> "(#{size})"
    end
  end

  defp column_options(opts) do
    default = column_default(Keyword.get(opts, :default))
    null = if Keyword.get(opts, :null) == false, do: " NOT NULL", else: ""
    pk = if Keyword.get(opts, :primary_key), do: " PRIMARY KEY", else: ""

    "#{pk}#{null}#{default}"
  end

  defp column_default(nil), do: ""
  defp column_default(true), do: " DEFAULT 1"
  defp column_default(false), do: " DEFAULT 0"
  defp column_default(value) when is_binary(value), do: " DEFAULT '#{escape_string(value)}'"
  defp column_default(value) when is_number(value), do: " DEFAULT #{value}"
  defp column_default({:fragment, expr}), do: " DEFAULT #{expr}"

  defp table_options(table, columns) do
    pk =
      Enum.filter(columns, fn {:add, _name, _type, opts} ->
        Keyword.get(opts, :primary_key, false)
      end)

    cond do
      length(pk) > 1 ->
        pk_names = Enum.map_join(pk, ", ", fn {:add, name, _type, _opts} -> quote_name(name) end)
        ", PRIMARY KEY (#{pk_names})"

      table.options ->
        # Handle custom table options
        ""

      true ->
        ""
    end
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
  def all(query) do
    sources = create_names(query)

    from = "FROM #{from(query, sources)}"
    select = select(query, sources)
    join = join(query, sources)
    where = where(query, sources)
    group_by = group_by(query, sources)
    having = having(query, sources)
    window = window(query, sources)
    combination = combination(query)
    order_by = order_by(query, sources)
    limit = limit(query, sources)
    offset = offset(query, sources)
    lock = lock(query, sources)

    [select, from, join, where, group_by, having, window, combination, order_by, limit, offset | lock]
  end

  @impl true
  def update_all(query) do
    sources = create_names(query)
    {from, name} = get_source(query, sources, 0)

    fields = update_fields(query, sources)
    {join, wheres} = using_join(query, :update_all, "FROM", sources)
    where = where(%{query | wheres: wheres}, sources)

    ["UPDATE #{quote_table(from)} AS #{name}",
     "SET", fields,
     join,
     where]
  end

  @impl true
  def delete_all(query) do
    sources = create_names(query)
    {from, name} = get_source(query, sources, 0)

    {join, wheres} = using_join(query, :delete_all, "USING", sources)
    where = where(%{query | wheres: wheres}, sources)

    ["DELETE FROM #{quote_table(from)} AS #{name}", join, where]
  end

  @impl true
  def insert(prefix, table, _header, rows, _on_conflict, returning, _placeholders) do
    values =
      if rows == [] do
        [" DEFAULT VALUES"]
      else
        [" (", intersperse_map(rows, ?,, &quote_value/1), ")"]
      end

    ["INSERT INTO ", quote_table(prefix, table), values | returning(returning)]
  end

  @impl true
  def update(prefix, table, fields, filters, _returning) do
    {fields, count} = intersperse_reduce(fields, ", ", 1, fn field, acc ->
      {[quote_name(field), " = ?#{acc}"], acc + 1}
    end)

    {filters, _count} = intersperse_reduce(filters, " AND ", count, fn field, acc ->
      {[quote_name(field), " = ?#{acc}"], acc + 1}
    end)

    ["UPDATE ", quote_table(prefix, table), " SET ",
     fields, " WHERE ", filters]
  end

  @impl true
  def delete(prefix, table, filters, _returning) do
    {filters, _} = intersperse_reduce(filters, " AND ", 1, fn field, acc ->
      {[quote_name(field), " = ?#{acc}"], acc + 1}
    end)

    ["DELETE FROM ", quote_table(prefix, table), " WHERE ", filters]
  end

  @impl true
  def explain_query(conn, query, params, opts) do
    {query, params, _opts} = all(query)
    query = "EXPLAIN QUERY PLAN " <> query
    execute(conn, query, params, opts)
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
    results = Enum.map(queries, fn q ->
      case execute(conn, String.trim(q), params, opts) do
        {:ok, result} -> result
        {:error, _} = error -> error
      end
    end)
    {:ok, results}
  end

  ## Helpers for query generation

  defp create_names(%{sources: sources}) do
    create_names(sources, 0, tuple_size(sources)) |> List.to_tuple()
  end

  defp create_names(sources, pos, limit) when pos < limit do
    [create_name(sources, pos) | create_names(sources, pos + 1, limit)]
  end

  defp create_names(_sources, pos, pos) do
    []
  end

  defp create_name(sources, pos) do
    case elem(sources, pos) do
      {table, schema, _} ->
        {quote_table(nil, table), schema}
      {:fragment, _, _} ->
        {nil, nil}
      %Ecto.SubQuery{} ->
        {nil, nil}
    end
  end

  defp from(%{from: %{source: source}} = query, sources) do
    {from, name} = get_source(query, sources, 0)
    [from, " AS ", name]
  end

  defp get_source(_query, sources, ix) do
    {source, _schema} = elem(sources, ix)
    {source, [?s, Integer.to_string(ix)]}
  end

  defp select(%{select: select} = query, sources) do
    ["SELECT ", select_fields(select, sources, query)]
  end

  defp select_fields(%{fields: fields}, sources, query) do
    intersperse_map(fields, ", ", fn
      {:&, _, [idx]} ->
        {_source, schema} = elem(sources, idx)
        if schema do
          Enum.map_join(schema.__schema__(:fields), ", ", &[quote_name(&1)])
        else
          "*"
        end

      {key, _value} when is_atom(key) ->
        [quote_name(key)]

      value ->
        expr(value, sources, query)
    end)
  end

  defp join(%{joins: []}, _sources), do: []
  defp join(%{joins: joins} = query, sources) do
    [?\s | intersperse_map(joins, ?\s, fn
      %Ecto.Query.JoinExpr{on: %{expr: expr}, qual: qual, ix: ix, source: source} ->
        {join, name} = get_source(query, sources, ix)
        [join_qual(qual), join, " AS ", name, " ON ", expr(expr, sources, query)]
    end)]
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
    [" GROUP BY " |
     intersperse_map(group_bys, ", ", fn
       %Ecto.Query.QueryExpr{expr: expr} ->
         intersperse_map(expr, ", ", &expr(&1, sources, query))
     end)]
  end

  defp window(%{windows: []}, _sources), do: []
  defp window(%{windows: windows} = query, sources) do
    intersperse_map(windows, ", ", fn {name, %{expr: kw}} ->
      [quote_name(name), " AS ", window_exprs(kw, sources, query)]
    end)
  end

  defp window_exprs(kw, sources, query) do
    [?(,
     if kw[:partition_by] != [], do: window_partition_by(kw, sources, query), else: [],
     window_order_by(kw, sources, query),
     ?)]
  end

  defp window_partition_by(kw, sources, query) do
    [" PARTITION BY " | intersperse_map(kw[:partition_by], ", ", &expr(&1, sources, query))]
  end

  defp window_order_by(kw, sources, query) do
    [" ORDER BY " | intersperse_map(kw[:order_by], ", ", &order_by_expr(&1, sources, query))]
  end

  defp order_by(%{order_bys: []}, _sources), do: []
  defp order_by(%{order_bys: order_bys} = query, sources) do
    [" ORDER BY " |
     intersperse_map(order_bys, ", ", fn %Ecto.Query.QueryExpr{expr: expr} ->
       intersperse_map(expr, ", ", &order_by_expr(&1, sources, query))
     end)]
  end

  defp order_by_expr({dir, expr}, sources, query) do
    str = expr(expr, sources, query)
    case dir do
      :asc  -> str
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

  defp lock(query, _sources), do: []

  defp boolean(_name, [], _sources, _query), do: []
  defp boolean(name, [%{expr: expr, op: op} | query_exprs], sources, query) do
    [name,
     Enum.reduce(query_exprs, {op, paren_expr(expr, sources, query)}, fn
       %{expr: expr, op: op}, {op, acc} ->
         {op, [acc, operator_to_boolean(op), paren_expr(expr, sources, query)]}
       %{expr: expr, op: op}, {_, acc} ->
         {op, [?(, acc, ?), operator_to_boolean(op), paren_expr(expr, sources, query)]}
     end) |> elem(1)]
  end

  defp operator_to_boolean(:and), do: " AND "
  defp operator_to_boolean(:or), do: " OR "

  defp paren_expr(expr, sources, query) do
    [?(, expr(expr, sources, query), ?)]
  end

  defp expr(expr, _sources, _query) do
    # Simplified expression handling - full implementation would handle all Ecto.Query expression types
    "?"
  end

  defp combination(%{combinations: []}), do: []
  defp combination(%{combinations: combinations}) do
    []
  end

  defp update_fields(%{updates: updates} = query, sources) do
    for(%{expr: expr} <- updates,
        {op, kw} <- expr,
        {key, value} <- kw,
        do: update_op(op, key, value, sources, query))
    |> Enum.intersperse(", ")
  end

  defp update_op(:set, key, value, sources, query) do
    [quote_name(key), " = ", expr(value, sources, query)]
  end

  defp update_op(:inc, key, value, sources, query) do
    [quote_name(key), " = ", quote_name(key), " + ", expr(value, sources, query)]
  end

  defp using_join(%{joins: []}, _kind, _prefix, _sources), do: {[], []}
  defp using_join(%{joins: joins} = query, kind, prefix, sources) do
    {[], query.wheres}
  end

  defp returning([]), do: []
  defp returning(_returning), do: []

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

  defp quote_value(nil), do: "NULL"
  defp quote_value(true), do: "1"
  defp quote_value(false), do: "0"
  defp quote_value(value) when is_binary(value) do
    [?', escape_string(value), ?']
  end
  defp quote_value(value) when is_integer(value) or is_float(value) do
    to_string(value)
  end
end
