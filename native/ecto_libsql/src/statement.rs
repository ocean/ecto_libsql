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

    let stmt_result = TOKIO_RUNTIME.block_on(async {
        let conn_guard = utils::safe_lock_arc(&connection, "prepare_statement conn")?;

        conn_guard
            .prepare(&sql_to_prepare)
            .await
            .map_err(|e| rustler::Error::Term(Box::new(format!("Prepare failed: {}", e))))
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
                    .map_err(|e| rustler::Error::Term(Box::new(format!("{:?}", e))))?;

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

    let result = TOKIO_RUNTIME.block_on(async {
        // Use cached statement with reset to clear bindings
        let stmt_guard = utils::safe_lock_arc(&cached_stmt, "execute_prepared stmt")?;

        // Reset clears any previous bindings
        stmt_guard.reset();

        let affected = stmt_guard
            .execute(decoded_args)
            .await
            .map_err(|e| rustler::Error::Term(Box::new(format!("Execute failed: {}", e))))?;

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
