/// Prepared statement management for LibSQL databases.
///
/// This module handles prepared statements, including:
/// - Preparing SQL statements for efficient reuse
/// - Executing prepared queries and statements
/// - Introspecting statement structure (column count, names, parameter count)
/// - Statement ownership verification
///
/// Prepared statements are cached in a registry and identified by statement IDs.
/// Each statement is associated with a connection ID to prevent cross-connection misuse.
use crate::{
    constants::{CONNECTION_REGISTRY, STMT_REGISTRY, TOKIO_RUNTIME},
    decode, utils,
};
use libsql::Value;
use rustler::{Atom, Env, NifResult, Term};
use std::sync::{Arc, Mutex};

/// Prepare a SQL statement for reuse.
///
/// Statements are cached internally and identified by a unique statement ID.
/// The same statement can be executed multiple times with different parameters.
///
/// # Arguments
/// - `conn_id`: Database connection ID
/// - `sql`: SQL query string to prepare
///
/// Returns a statement ID on success, error on failure.
#[rustler::nif(schedule = "DirtyIo")]
pub fn prepare_statement(conn_id: &str, sql: &str) -> NifResult<String> {
    let client = {
        let conn_map = utils::safe_lock(&CONNECTION_REGISTRY, "prepare_statement conn_map")?;
        conn_map
            .get(conn_id)
            .cloned()
            .ok_or_else(|| rustler::Error::Term(Box::new("Invalid connection ID")))?
    };

    let sql_to_prepare = sql.to_string();

    // Clone the inner connection Arc and drop the outer lock before async operations
    let connection = {
        let client_guard = utils::safe_lock_arc(&client, "prepare_statement client")?;
        client_guard.client.clone()
    }; // Outer lock dropped here

    // SAFETY: We use TOKIO_RUNTIME.block_on(), which runs the future synchronously on a dedicated
    // thread pool. This prevents deadlocks that could occur if we were in a true async context
    // with std::sync::Mutex guards held across await points.
    #[allow(clippy::await_holding_lock)]
    let stmt_result = TOKIO_RUNTIME.block_on(async {
        let conn_guard = utils::safe_lock_arc(&connection, "prepare_statement conn")?;

        conn_guard
            .prepare(&sql_to_prepare)
            .await
            .map_err(|e| rustler::Error::Term(Box::new(format!("Prepare failed: {e}"))))
    });

    match stmt_result {
        Ok(stmt) => {
            let stmt_id = uuid::Uuid::new_v4().to_string();
            utils::safe_lock(&STMT_REGISTRY, "prepare_statement stmt_registry")?.insert(
                stmt_id.clone(),
                (conn_id.to_string(), Arc::new(Mutex::new(stmt))),
            );
            Ok(stmt_id)
        }
        Err(e) => Err(e),
    }
}

/// Execute a prepared SELECT query or RETURNING clause.
///
/// Use this for SELECT statements or INSERT/UPDATE/DELETE with RETURNING clause.
/// For statements that don't return rows, use `execute_prepared` instead.
///
/// # Arguments
/// - `env`: Elixir environment
/// - `conn_id`: Database connection ID
/// - `stmt_id`: Prepared statement ID
/// - `_mode`: Connection mode (unused, for API compatibility)
/// - `_syncx`: Sync mode (unused, for API compatibility)
/// - `args`: Query parameters
#[rustler::nif(schedule = "DirtyIo")]
pub fn query_prepared<'a>(
    env: Env<'a>,
    conn_id: &str,
    stmt_id: &str,
    _mode: Atom,
    _syncx: Atom,
    args: Vec<Term<'a>>,
) -> NifResult<Term<'a>> {
    let conn_map = utils::safe_lock(&CONNECTION_REGISTRY, "query_prepared conn_map")?;
    let stmt_registry = utils::safe_lock(&STMT_REGISTRY, "query_prepared stmt_registry")?;

    if conn_map.get(conn_id).is_none() {
        return Err(rustler::Error::Term(Box::new("Invalid connection ID")));
    }

    let (stored_conn_id, cached_stmt) = stmt_registry
        .get(stmt_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Statement not found")))?;

    // Verify statement belongs to this connection
    decode::verify_statement_ownership(stored_conn_id, conn_id)?;

    let cached_stmt = cached_stmt.clone();

    let decoded_args: Vec<Value> = args
        .into_iter()
        .map(|t| utils::decode_term_to_value(t))
        .collect::<Result<_, _>>()
        .map_err(|e| rustler::Error::Term(Box::new(e)))?;

    drop(stmt_registry); // Release lock before async operation
    drop(conn_map); // Release lock before async operation

    // SAFETY: We use TOKIO_RUNTIME.block_on(), which runs the future synchronously on a dedicated
    // thread pool. This prevents deadlocks that could occur if we were in a true async context
    // with std::sync::Mutex guards held across await points.
    #[allow(clippy::await_holding_lock)]
    let result = TOKIO_RUNTIME.block_on(async {
        // Use cached statement with reset to clear bindings
        let stmt_guard = utils::safe_lock_arc(&cached_stmt, "query_prepared stmt")?;

        // Reset clears any previous bindings
        stmt_guard.reset();

        let res = stmt_guard.query(decoded_args).await;

        match res {
            Ok(rows) => {
                let collected = utils::collect_rows(env, rows)
                    .await
                    .map_err(|e| rustler::Error::Term(Box::new(format!("{e:?}"))))?;

                Ok(collected)
            }
            Err(e) => Err(rustler::Error::Term(Box::new(e.to_string()))),
        }
    });

    result
}

/// Execute a prepared statement that doesn't return rows.
///
/// Use this for INSERT, UPDATE, DELETE statements without RETURNING clause.
/// For statements that return rows, use `query_prepared` instead.
///
/// Returns the number of affected rows.
///
/// # Arguments
/// - `env`: Elixir environment (unused in this function, kept for API consistency)
/// - `conn_id`: Database connection ID
/// - `stmt_id`: Prepared statement ID
/// - `mode`: Connection mode (unused, for API compatibility)
/// - `syncx`: Sync mode (unused, for API compatibility)
/// - `sql_hint`: Original SQL for detecting if we need sync
/// - `args`: Query parameters
#[rustler::nif(schedule = "DirtyIo")]
#[allow(unused_variables)]
pub fn execute_prepared<'a>(
    env: Env<'a>,
    conn_id: &str,
    stmt_id: &str,
    mode: Atom,
    syncx: Atom,
    sql_hint: &str, // For detecting if we need sync
    args: Vec<Term<'a>>,
) -> NifResult<u64> {
    let conn_map = utils::safe_lock(&CONNECTION_REGISTRY, "execute_prepared conn_map")?;
    let stmt_registry = utils::safe_lock(&STMT_REGISTRY, "execute_prepared stmt_registry")?;

    if conn_map.get(conn_id).is_none() {
        return Err(rustler::Error::Term(Box::new("Invalid connection ID")));
    }

    let (stored_conn_id, cached_stmt) = stmt_registry
        .get(stmt_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Statement not found")))?;

    // Verify statement belongs to this connection
    decode::verify_statement_ownership(stored_conn_id, conn_id)?;

    let cached_stmt = cached_stmt.clone();

    let decoded_args: Vec<Value> = args
        .into_iter()
        .map(|t| utils::decode_term_to_value(t))
        .collect::<Result<_, _>>()
        .map_err(|e| rustler::Error::Term(Box::new(e)))?;

    drop(stmt_registry); // Release lock before async operation
    drop(conn_map); // Release lock before async operation

    // SAFETY: We use TOKIO_RUNTIME.block_on(), which runs the future synchronously on a dedicated
    // thread pool. This prevents deadlocks that could occur if we were in a true async context
    // with std::sync::Mutex guards held across await points.
    #[allow(clippy::await_holding_lock)]
    let result = TOKIO_RUNTIME.block_on(async {
        // Use cached statement with reset to clear bindings
        let stmt_guard = utils::safe_lock_arc(&cached_stmt, "execute_prepared stmt")?;

        // Reset clears any previous bindings
        stmt_guard.reset();

        let affected = stmt_guard
            .execute(decoded_args)
            .await
            .map_err(|e| rustler::Error::Term(Box::new(format!("Execute failed: {e}"))))?;

        // NOTE: LibSQL automatically syncs writes to remote for embedded replicas.
        // No manual sync needed here.

        Ok(affected as u64)
    });

    result
}

/// Get the number of columns in a prepared statement's result set.
///
/// This is useful for understanding the structure of a SELECT query
/// or RETURNING clause before executing it.
///
/// # Arguments
/// - `conn_id`: Database connection ID
/// - `stmt_id`: Prepared statement ID
#[rustler::nif(schedule = "DirtyIo")]
pub fn statement_column_count(conn_id: &str, stmt_id: &str) -> NifResult<usize> {
    let conn_map = utils::safe_lock(&CONNECTION_REGISTRY, "statement_column_count conn_map")?;
    let stmt_registry = utils::safe_lock(&STMT_REGISTRY, "statement_column_count stmt_registry")?;

    if conn_map.get(conn_id).is_none() {
        return Err(rustler::Error::Term(Box::new("Invalid connection ID")));
    }

    let (stored_conn_id, cached_stmt) = stmt_registry
        .get(stmt_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Statement not found")))?;

    // Verify statement belongs to this connection
    decode::verify_statement_ownership(stored_conn_id, conn_id)?;

    let cached_stmt = cached_stmt.clone();

    drop(stmt_registry);
    drop(conn_map);

    let stmt_guard = utils::safe_lock_arc(&cached_stmt, "statement_column_count stmt")?;
    let count = stmt_guard.column_count();

    Ok(count)
}

/// Get the name of a column in a prepared statement by its index.
///
/// Useful for understanding column names without executing the query.
/// Index is 0-based. Returns error if index is out of bounds.
///
/// # Arguments
/// - `conn_id`: Database connection ID
/// - `stmt_id`: Prepared statement ID
/// - `idx`: Column index (0-based)
#[rustler::nif(schedule = "DirtyIo")]
pub fn statement_column_name(conn_id: &str, stmt_id: &str, idx: usize) -> NifResult<String> {
    let conn_map = utils::safe_lock(&CONNECTION_REGISTRY, "statement_column_name conn_map")?;
    let stmt_registry = utils::safe_lock(&STMT_REGISTRY, "statement_column_name stmt_registry")?;

    if conn_map.get(conn_id).is_none() {
        return Err(rustler::Error::Term(Box::new("Invalid connection ID")));
    }

    let (stored_conn_id, cached_stmt) = stmt_registry
        .get(stmt_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Statement not found")))?;

    // Verify statement belongs to this connection
    decode::verify_statement_ownership(stored_conn_id, conn_id)?;

    let cached_stmt = cached_stmt.clone();

    drop(stmt_registry);
    drop(conn_map);

    let stmt_guard = utils::safe_lock_arc(&cached_stmt, "statement_column_name stmt")?;
    let columns = stmt_guard.columns();

    if idx >= columns.len() {
        return Err(rustler::Error::Term(Box::new(format!(
            "Column index {} out of bounds (statement has {} columns)",
            idx,
            columns.len()
        ))));
    }

    let column_name = columns[idx].name().to_string();

    Ok(column_name)
}

/// Get the number of parameters in a prepared statement.
///
/// Parameters are placeholders (?) in the SQL that need to be bound
/// when executing the statement.
///
/// # Arguments
/// - `conn_id`: Database connection ID
/// - `stmt_id`: Prepared statement ID
#[rustler::nif(schedule = "DirtyIo")]
pub fn statement_parameter_count(conn_id: &str, stmt_id: &str) -> NifResult<usize> {
    let conn_map = utils::safe_lock(&CONNECTION_REGISTRY, "statement_parameter_count conn_map")?;
    let stmt_registry =
        utils::safe_lock(&STMT_REGISTRY, "statement_parameter_count stmt_registry")?;

    if conn_map.get(conn_id).is_none() {
        return Err(rustler::Error::Term(Box::new("Invalid connection ID")));
    }

    let (stored_conn_id, cached_stmt) = stmt_registry
        .get(stmt_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Statement not found")))?;

    // Verify statement belongs to this connection
    decode::verify_statement_ownership(stored_conn_id, conn_id)?;

    let cached_stmt = cached_stmt.clone();

    drop(stmt_registry);
    drop(conn_map);

    let stmt_guard = utils::safe_lock_arc(&cached_stmt, "statement_parameter_count stmt")?;
    let count = stmt_guard.parameter_count();

    Ok(count)
}

/// Get the name of a parameter in a prepared statement by its index.
///
/// Returns the parameter name if it's a named parameter (e.g., `:name`, `@name`, `$name`),
/// or `None` if it's a positional parameter (`?`).
///
/// This is useful for understanding the parameter names in queries that use
/// named parameters instead of positional placeholders.
///
/// # Arguments
/// - `conn_id`: Database connection ID
/// - `stmt_id`: Prepared statement ID
/// - `idx`: Parameter index (1-based, following SQLite convention)
///
/// # Returns
/// - `{:ok, name}` - Parameter has a name (e.g., `:name` returns `"name"`)
/// - `{:ok, nil}` - Parameter is positional (`?`)
/// - `{:error, reason}` - Error occurred
///
/// # Note
/// Parameter indices in SQLite are 1-based, not 0-based. The first parameter is index 1.
#[rustler::nif(schedule = "DirtyIo")]
pub fn statement_parameter_name(
    conn_id: &str,
    stmt_id: &str,
    idx: i32,
) -> NifResult<Option<String>> {
    let conn_map = utils::safe_lock(&CONNECTION_REGISTRY, "statement_parameter_name conn_map")?;
    let stmt_registry = utils::safe_lock(&STMT_REGISTRY, "statement_parameter_name stmt_registry")?;

    if conn_map.get(conn_id).is_none() {
        return Err(rustler::Error::Term(Box::new("Invalid connection ID")));
    }

    let (stored_conn_id, cached_stmt) = stmt_registry
        .get(stmt_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Statement not found")))?;

    // Verify statement belongs to this connection
    decode::verify_statement_ownership(stored_conn_id, conn_id)?;

    let cached_stmt = cached_stmt.clone();

    drop(stmt_registry);
    drop(conn_map);

    let stmt_guard = utils::safe_lock_arc(&cached_stmt, "statement_parameter_name stmt")?;

    // SQLite uses 1-based parameter indices
    let param_name = stmt_guard.parameter_name(idx).map(|s| s.to_string());

    Ok(param_name)
}

/// Reset a prepared statement to its initial state for reuse.
///
/// After executing a statement, you should reset it before binding new parameters
/// and executing again. This allows efficient statement reuse without re-preparing.
///
/// **Performance Note**: Resetting and reusing statements is much faster than
/// re-preparing the same SQL string repeatedly. Always reset statements when
/// executing the same query multiple times with different parameters.
///
/// # Arguments
/// - `conn_id`: Database connection ID
/// - `stmt_id`: Prepared statement ID
///
/// # Returns
/// - `:ok` - Statement reset successfully
/// - `{:error, reason}` - Reset failed
///
/// # Example
/// ```elixir
/// {:ok, stmt_id} = EctoLibSql.prepare(state, "INSERT INTO logs (msg) VALUES (?)")
///
/// for msg <- messages do
///   EctoLibSql.execute_stmt(state, stmt_id, [msg])
///   EctoLibSql.reset_stmt(state, stmt_id)  # ← Reset for next iteration
/// end
///
/// EctoLibSql.close_stmt(state, stmt_id)
/// ```
#[rustler::nif(schedule = "DirtyIo")]
pub fn reset_statement(conn_id: &str, stmt_id: &str) -> NifResult<Atom> {
    let conn_map = utils::safe_lock(&CONNECTION_REGISTRY, "reset_statement conn_map")?;
    let stmt_registry = utils::safe_lock(&STMT_REGISTRY, "reset_statement stmt_registry")?;

    if conn_map.get(conn_id).is_none() {
        return Err(rustler::Error::Term(Box::new("Invalid connection ID")));
    }

    let (stored_conn_id, cached_stmt) = stmt_registry
        .get(stmt_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Statement not found")))?;

    // Verify statement belongs to this connection
    decode::verify_statement_ownership(stored_conn_id, conn_id)?;

    let cached_stmt = cached_stmt.clone();

    drop(stmt_registry);
    drop(conn_map);

    let stmt_guard = utils::safe_lock_arc(&cached_stmt, "reset_statement stmt")?;
    stmt_guard.reset();

    Ok(rustler::types::atom::ok())
}

/// Get column metadata for a prepared statement.
///
/// Returns information about all columns that will be returned when the
/// statement is executed. This includes column names and declared types.
///
/// # Arguments
/// - `conn_id`: Database connection ID
/// - `stmt_id`: Prepared statement ID
///
/// # Returns
/// - `{:ok, columns}` - List of maps with `:name` and `:decl_type` keys
/// - `{:error, reason}` - Failed to get metadata
///
/// # Example
/// ```elixir
/// {:ok, stmt_id} = EctoLibSql.prepare(state, "SELECT id, name, age FROM users")
/// {:ok, columns} = EctoLibSql.get_statement_columns(state, stmt_id)
/// # Returns: [
/// #   %{name: "id", decl_type: "INTEGER"},
/// #   %{name: "name", decl_type: "TEXT"},
/// #   %{name: "age", decl_type: "INTEGER"}
/// # ]
/// ```
#[rustler::nif(schedule = "DirtyIo")]
pub fn get_statement_columns(
    conn_id: &str,
    stmt_id: &str,
) -> NifResult<Vec<(String, String, Option<String>)>> {
    let conn_map = utils::safe_lock(&CONNECTION_REGISTRY, "get_statement_columns conn_map")?;
    let stmt_registry = utils::safe_lock(&STMT_REGISTRY, "get_statement_columns stmt_registry")?;

    if conn_map.get(conn_id).is_none() {
        return Err(rustler::Error::Term(Box::new("Invalid connection ID")));
    }

    let (stored_conn_id, cached_stmt) = stmt_registry
        .get(stmt_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Statement not found")))?;

    // Verify statement belongs to this connection
    decode::verify_statement_ownership(stored_conn_id, conn_id)?;

    let cached_stmt = cached_stmt.clone();

    drop(stmt_registry);
    drop(conn_map);

    let stmt_guard = utils::safe_lock_arc(&cached_stmt, "get_statement_columns stmt")?;
    let columns = stmt_guard.columns();

    // Build list of column metadata tuples: (name, origin_name, decl_type)
    let column_info: Vec<(String, String, Option<String>)> = columns
        .iter()
        .map(|col| {
            let name = col.name().to_string();
            let origin_name = col
                .origin_name()
                .map(|s| s.to_string())
                .unwrap_or_else(|| name.clone());
            let decl_type = col.decl_type().map(|s| s.to_string());
            (name, origin_name, decl_type)
        })
        .collect();

    Ok(column_info)
}
