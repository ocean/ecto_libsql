/// Basic query execution and synchronization
///
/// This module handles executing SQL queries, returning results, and managing
/// manual synchronization for remote replicas.
use crate::constants::*;
use crate::utils::{
    build_empty_result, collect_rows, enhance_constraint_error, safe_lock, safe_lock_arc,
    should_use_query, validate_utf8_sql,
};
use libsql::Value;
use rustler::{Atom, Env, NifResult, Term};

/// Execute a SQL query with arguments and return results.
///
/// Handles both SELECT queries and DML statements (INSERT/UPDATE/DELETE).
/// Automatically routes to `query()` for statements that return rows or `execute()` for those
/// that don't, optimizing performance based on statement type.
///
/// **Error Enhancement**: Constraint violation errors are enhanced with index names to support
/// Ecto's `unique_constraint/3` and other constraint handling features.
///
/// **Automatic Sync**: For remote replicas, writes are automatically synced to the remote database
/// by LibSQL. Manual sync is still available via `do_sync()` for explicit control.
///
/// # Arguments
/// - `env`: Elixir environment
/// - `conn_id`: Database connection ID
/// - `query`: SQL query string
/// - `args`: Query parameter values
///
/// Returns a map with keys: `columns`, `rows`, `num_rows`
#[rustler::nif(schedule = "DirtyIo")]
pub fn query_args<'a>(
    env: Env<'a>,
    conn_id: &str,
    _mode: Atom,
    _syncx: Atom,
    query: &str,
    args: Vec<Term<'a>>,
) -> NifResult<Term<'a>> {
    // Validate UTF-8 as defence against CVE-2025-47736.
    validate_utf8_sql(query)?;

    let client = {
        let conn_map = safe_lock(&CONNECTION_REGISTRY, "query_args conn_map")?;
        conn_map
            .get(conn_id)
            .cloned()
            .ok_or_else(|| rustler::Error::Term(Box::new("Invalid connection ID")))?
    }; // Lock dropped here

    let params: Result<Vec<Value>, _> = args
        .into_iter()
        .map(|t| crate::utils::decode_term_to_value(t))
        .collect();

    let params = params.map_err(|e| rustler::Error::Term(Box::new(e)))?;

    // Determine whether to use query() or execute() based on statement
    let use_query = should_use_query(query);

    // Clone the inner connection Arc and drop the outer lock before async operations
    // This reduces lock coupling and prevents holding the LibSQLConn lock during I/O
    let connection = {
        let client_guard = safe_lock_arc(&client, "query_args client")?;
        client_guard.client.clone()
    }; // Outer lock dropped here

    // SAFETY: We're inside TOKIO_RUNTIME.block_on(), so this is synchronous execution.
    // The std::sync::Mutex guards are safe to hold across await points here because
    // we're not in a true async context - block_on runs the future to completion.
    #[allow(clippy::await_holding_lock)]
    {
        TOKIO_RUNTIME.block_on(async {
            let conn_guard: std::sync::MutexGuard<libsql::Connection> =
                safe_lock_arc(&connection, "query_args conn")?;

            // NOTE: LibSQL automatically syncs writes to remote for embedded replicas.
            // According to Turso docs, "writes are sent to the remote primary database by default,
            // then the local database updates automatically once the remote write succeeds."
            // We do NOT need to manually call sync() after writes - that would be redundant
            // and cause performance issues. Manual sync via do_sync() is still available for
            // explicit user control.

            if use_query {
                // Statements that return rows (SELECT, or INSERT/UPDATE/DELETE with RETURNING)
                let res = conn_guard.query(query, params).await;

                match res {
                    Ok(res_rows) => {
                        let result = collect_rows(env, res_rows).await?;
                        Ok(result)
                    }
                    Err(e) => {
                        let error_msg = e.to_string();
                        let enhanced_msg = enhance_constraint_error(&conn_guard, &error_msg)
                            .await
                            .unwrap_or(error_msg);
                        Err(rustler::Error::Term(Box::new(enhanced_msg)))
                    }
                }
            } else {
                // Statements that don't return rows (INSERT/UPDATE/DELETE without RETURNING)
                let res = conn_guard.execute(query, params).await;

                match res {
                    Ok(rows_affected) => Ok(build_empty_result(env, rows_affected)),
                    Err(e) => {
                        let error_msg = e.to_string();
                        let enhanced_msg = enhance_constraint_error(&conn_guard, &error_msg)
                            .await
                            .unwrap_or(error_msg);
                        Err(rustler::Error::Term(Box::new(enhanced_msg)))
                    }
                }
            }
        })
    }
}

/// Manually synchronize a remote replica database with the remote primary.
///
/// For remote replicas, this triggers an explicit sync operation to pull the latest
/// changes from the remote database. This is useful when you need to ensure read-after-write
/// consistency or when automatic sync is disabled.
///
/// For local and direct remote connections, this is a no-op.
///
/// **Timeout**: Sync operations have a 30-second timeout to prevent indefinite blocking.
///
/// # Arguments
/// - `conn_id`: Database connection ID
/// - `mode`: Connection mode (`:local`, `:remote`, `:remote_replica`)
///
/// Returns `{:ok, "success sync"}` on success, error on failure.
#[rustler::nif(schedule = "DirtyIo")]
pub fn do_sync(conn_id: &str, mode: Atom) -> NifResult<(Atom, String)> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "do_sync")?;
    let client = conn_map
        .get(conn_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Connection not found")))?
        .clone();

    drop(conn_map); // Release lock before async operation

    let result = TOKIO_RUNTIME.block_on(async {
        if matches!(
            crate::decode::decode_mode(mode),
            Some(crate::models::Mode::RemoteReplica)
        ) {
            crate::utils::sync_with_timeout(&client, DEFAULT_SYNC_TIMEOUT_SECS).await?;
        }

        Ok::<_, String>(())
    });

    match result {
        Ok(()) => Ok((rustler::types::atom::ok(), "success sync".to_string())),
        Err(e) => Err(rustler::Error::Term(Box::new(e))),
    }
}

/// Execute a PRAGMA statement and return the result.
///
/// PRAGMA statements are SQLite's configuration mechanism. They allow you to query
/// and modify database settings without modifying data.
///
/// Common PRAGMA statements:
/// - `PRAGMA foreign_keys = ON` - Enable foreign key constraints
/// - `PRAGMA journal_mode = WAL` - Set write-ahead logging mode
/// - `PRAGMA synchronous = NORMAL` - Set synchronisation level
/// - `PRAGMA foreign_keys` - Query current foreign key setting
/// - `PRAGMA table_list` - List all tables in the database
///
/// Some PRAGMAs return values (e.g., `PRAGMA foreign_keys`), others just set values.
/// Always returns a result map with columns and rows (may be empty for set-only PRAGMAs).
///
/// # Arguments
/// - `env`: Elixir environment
/// - `conn_id`: Database connection ID
/// - `pragma_stmt`: Complete PRAGMA statement (e.g., "PRAGMA journal_mode = WAL")
///
/// Returns a map with keys: `columns`, `rows`, `num_rows`
#[rustler::nif(schedule = "DirtyIo")]
pub fn pragma_query<'a>(env: Env<'a>, conn_id: &str, pragma_stmt: &str) -> NifResult<Term<'a>> {
    // Validate UTF-8 as defence against CVE-2025-47736.
    validate_utf8_sql(pragma_stmt)?;

    let conn_map = safe_lock(&CONNECTION_REGISTRY, "pragma_query conn_map")?;

    if let Some(client) = conn_map.get(conn_id) {
        let client = client.clone();
        drop(conn_map); // Release lock before async operation

        // SAFETY: We're inside TOKIO_RUNTIME.block_on(), so this is synchronous execution.
        // The std::sync::Mutex guards are safe to hold across await points here because
        // we're not in a true async context - block_on runs the future to completion.
        #[allow(clippy::await_holding_lock)]
        let result = TOKIO_RUNTIME.block_on(async {
            let client_guard = safe_lock_arc(&client, "pragma_query client")?;
            let conn_guard: std::sync::MutexGuard<libsql::Connection> =
                safe_lock_arc(&client_guard.client, "pragma_query conn")?;

            let rows = conn_guard
                .query(pragma_stmt, ())
                .await
                .map_err(|e| rustler::Error::Term(Box::new(format!("PRAGMA query failed: {e}"))))?;

            collect_rows(env, rows).await
        });

        result
    } else {
        Err(rustler::Error::Term(Box::new("Invalid connection ID")))
    }
}
