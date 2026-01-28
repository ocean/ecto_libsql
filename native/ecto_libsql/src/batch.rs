/// Batch operations for `LibSQL`/Turso databases
///
/// This module handles batch execution of multiple SQL statements, both with
/// and without transactional semantics. Supports both statement-level batch
/// execution (with parameterized queries) and native SQL batch execution.
use crate::constants::{CONNECTION_REGISTRY, TOKIO_RUNTIME};
use crate::utils::{collect_rows, decode_term_to_value, safe_lock, safe_lock_arc};
use libsql::Value;
use rustler::types::atom::nil;
use rustler::{Atom, Encoder, Env, NifResult, Term};

/// Execute multiple SQL statements sequentially without a transaction.
///
/// Each statement is executed independently - if one fails, others may still complete.
/// Statements are provided as a list of `{sql, params}` tuples.
///
/// **Automatic Sync**: For remote replicas, `LibSQL` automatically syncs writes to the
/// remote database. No manual sync is needed.
///
/// # Arguments
/// - `env`: Elixir environment
/// - `conn_id`: Database connection ID
/// - `_mode`: Connection mode (unused, kept for API compatibility)
/// - `_syncx`: Sync mode (unused, `LibSQL` handles sync automatically)
/// - `statements`: List of `{sql, params}` tuples
///
/// Returns a list of result maps (one per statement)
#[rustler::nif(schedule = "DirtyIo")]
pub fn execute_batch<'a>(
    env: Env<'a>,
    conn_id: &str,
    _mode: Atom,
    _syncx: Atom,
    statements: Vec<Term<'a>>,
) -> NifResult<Term<'a>> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "execute_batch conn_map")?;

    let client = conn_map
        .get(conn_id)
        .cloned()
        .ok_or_else(|| rustler::Error::Term(Box::new("Invalid connection ID")))?;

    drop(conn_map); // Release lock before async operation

    // Decode each statement with its arguments
    let mut batch_stmts: Vec<(String, Vec<Value>)> = Vec::new();
    for stmt_term in statements {
        let (query, args): (String, Vec<Term>) = stmt_term.decode().map_err(|e| {
            rustler::Error::Term(Box::new(format!("Failed to decode statement: {e:?}")))
        })?;

        let decoded_args: Vec<Value> = args
            .into_iter()
            .map(|t| decode_term_to_value(t))
            .collect::<Result<_, _>>()
            .map_err(|e| rustler::Error::Term(Box::new(e)))?;

        batch_stmts.push((query, decoded_args));
    }

    // SAFETY: We use TOKIO_RUNTIME.block_on(), which runs the future synchronously on a dedicated
    // thread pool. This prevents deadlocks that could occur if we were in a true async context
    // with std::sync::Mutex guards held across await points.
    #[allow(clippy::await_holding_lock)]
    TOKIO_RUNTIME.block_on(async {
        let mut all_results: Vec<Term<'a>> = Vec::new();

        // Execute each statement sequentially
        for (sql, args) in &batch_stmts {
            let client_guard = safe_lock_arc(&client, "execute_batch client")?;
            let conn_guard = safe_lock_arc(&client_guard.client, "execute_batch conn")?;
            let result = conn_guard.query(sql, args.clone()).await;

            match result {
                Ok(rows) => {
                    let collected = collect_rows(env, rows)
                        .await
                        .map_err(|e| rustler::Error::Term(Box::new(format!("{e:?}"))))?;
                    all_results.push(collected);
                }
                Err(e) => {
                    return Err(rustler::Error::Term(Box::new(format!(
                        "Batch statement error: {e}"
                    ))));
                }
            }
        }

        Ok(all_results.encode(env))
    })
}

/// Execute multiple SQL statements atomically within a transaction.
///
/// All statements execute in a single transaction. If any statement fails,
/// all changes are rolled back. Statements are provided as `{sql, params}` tuples.
///
/// **Automatic Sync**: For remote replicas, `LibSQL` automatically syncs writes to the
/// remote database after the transaction commits.
///
/// # Arguments
/// - `env`: Elixir environment
/// - `conn_id`: Database connection ID
/// - `_mode`: Connection mode (unused, kept for API compatibility)
/// - `_syncx`: Sync mode (unused, `LibSQL` handles sync automatically)
/// - `statements`: List of `{sql, params}` tuples
///
/// Returns a list of result maps (one per statement) on success, or rolls back all
/// changes on any error.
#[rustler::nif(schedule = "DirtyIo")]
pub fn execute_transactional_batch<'a>(
    env: Env<'a>,
    conn_id: &str,
    _mode: Atom,
    _syncx: Atom,
    statements: Vec<Term<'a>>,
) -> NifResult<Term<'a>> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "execute_transactional_batch conn_map")?;

    let client = conn_map
        .get(conn_id)
        .cloned()
        .ok_or_else(|| rustler::Error::Term(Box::new("Invalid connection ID")))?;

    drop(conn_map); // Release lock before async operation

    // Decode each statement with its arguments
    let mut batch_stmts: Vec<(String, Vec<Value>)> = Vec::new();
    for stmt_term in statements {
        let (query, args): (String, Vec<Term>) = stmt_term.decode().map_err(|e| {
            rustler::Error::Term(Box::new(format!("Failed to decode statement: {e:?}")))
        })?;

        let decoded_args: Vec<Value> = args
            .into_iter()
            .map(|t| decode_term_to_value(t))
            .collect::<Result<_, _>>()
            .map_err(|e| rustler::Error::Term(Box::new(e)))?;

        batch_stmts.push((query, decoded_args));
    }

    // SAFETY: We use TOKIO_RUNTIME.block_on(), which runs the future synchronously on a dedicated
    // thread pool. This prevents deadlocks that could occur if we were in a true async context
    // with std::sync::Mutex guards held across await points.
    #[allow(clippy::await_holding_lock)]
    TOKIO_RUNTIME.block_on(async {
        let client_guard = safe_lock_arc(&client, "execute_transactional_batch client")?;
        let conn_guard = safe_lock_arc(&client_guard.client, "execute_transactional_batch conn")?;
        let trx = conn_guard.transaction().await.map_err(|e| {
            rustler::Error::Term(Box::new(format!("Begin transaction failed: {e}")))
        })?;
        // Drop guards after transaction is started - the transaction owns its own connection
        drop(conn_guard);
        drop(client_guard);

        let mut all_results: Vec<Term<'a>> = Vec::new();

        // Execute each statement in the transaction
        for (sql, args) in &batch_stmts {
            match trx.query(sql, args.clone()).await {
                Ok(rows) => {
                    let collected = collect_rows(env, rows)
                        .await
                        .map_err(|e| rustler::Error::Term(Box::new(format!("{e:?}"))))?;
                    all_results.push(collected);
                }
                Err(e) => {
                    // Rollback on error
                    let _ = trx.rollback().await;
                    return Err(rustler::Error::Term(Box::new(format!(
                        "Batch statement error: {e}"
                    ))));
                }
            }
        }

        // Commit the transaction
        trx.commit()
            .await
            .map_err(|e| rustler::Error::Term(Box::new(format!("Commit failed: {e}"))))?;

        Ok(all_results.encode(env))
    })
}

/// Execute multiple SQL statements from a single string (semicolon-separated).
///
/// Uses `LibSQL`'s native batch execution for better performance. Each statement
/// is executed independently - if one fails, others may still complete.
///
/// This is useful for running SQL scripts or migrations where multiple statements
/// are concatenated into a single string.
///
/// # Arguments
/// - `env`: Elixir environment
/// - `conn_id`: Database connection ID
/// - `sql`: Multiple SQL statements separated by semicolons
///
/// Returns a list of results (one per statement). Results may be `nil` for
/// statements that don't return rows or conditional statements not executed.
#[rustler::nif(schedule = "DirtyIo")]
pub fn execute_batch_native<'a>(env: Env<'a>, conn_id: &str, sql: &str) -> NifResult<Term<'a>> {
    // UTF-8 validation is guaranteed by Rust's &str type and Rustler's conversion,
    // so we can rely on the type system rather than runtime checks.

    let conn_map = safe_lock(&CONNECTION_REGISTRY, "execute_batch_native conn_map")?;

    if let Some(client) = conn_map.get(conn_id) {
        let client = client.clone();
        drop(conn_map); // Release lock before async operation

        // SAFETY: We use TOKIO_RUNTIME.block_on(), which runs the future synchronously on a dedicated
        // thread pool. This prevents deadlocks that could occur if we were in a true async context
        // with std::sync::Mutex guards held across await points.
        #[allow(clippy::await_holding_lock)]
        let result = TOKIO_RUNTIME.block_on(async {
            let client_guard = safe_lock_arc(&client, "execute_batch_native client")?;
            let conn_guard = safe_lock_arc(&client_guard.client, "execute_batch_native conn")?;
            let mut batch_rows = conn_guard
                .execute_batch(sql)
                .await
                .map_err(|e| rustler::Error::Term(Box::new(format!("batch failed: {e}"))))?;
            // Drop guards after batch is retrieved
            drop(conn_guard);
            drop(client_guard);

            // Collect all results
            let mut results: Vec<Term<'a>> = Vec::new();
            while let Some(maybe_rows) = batch_rows.next_stmt_row() {
                match maybe_rows {
                    Some(rows) => {
                        // Collect rows from this statement
                        let collected = collect_rows(env, rows).await?;
                        results.push(collected);
                    }
                    None => {
                        // Statement was not executed (conditional)
                        results.push(nil().encode(env));
                    }
                }
            }

            Ok::<Term<'a>, rustler::Error>(results.encode(env))
        });

        result
    } else {
        Err(rustler::Error::Term(Box::new("Invalid connection ID")))
    }
}

/// Execute multiple SQL statements atomically in a transaction.
///
/// Uses `LibSQL`'s native transactional batch execution. All statements succeed
/// or all are rolled back. The SQL string contains multiple semicolon-separated
/// statements.
///
/// This provides better atomicity guarantees than `execute_batch_native` when
/// you need all-or-nothing semantics.
///
/// # Arguments
/// - `env`: Elixir environment
/// - `conn_id`: Database connection ID
/// - `sql`: Multiple SQL statements separated by semicolons
///
/// Returns a list of results (one per statement). Results may be `nil` for
/// statements that don't return rows or conditional statements not executed.
#[rustler::nif(schedule = "DirtyIo")]
pub fn execute_transactional_batch_native<'a>(
    env: Env<'a>,
    conn_id: &str,
    sql: &str,
) -> NifResult<Term<'a>> {
    let conn_map = safe_lock(
        &CONNECTION_REGISTRY,
        "execute_transactional_batch_native conn_map",
    )?;

    if let Some(client) = conn_map.get(conn_id) {
        let client = client.clone();
        drop(conn_map); // Release lock before async operation

        // SAFETY: We use TOKIO_RUNTIME.block_on(), which runs the future synchronously on a dedicated
        // thread pool. This prevents deadlocks that could occur if we were in a true async context
        // with std::sync::Mutex guards held across await points.
        #[allow(clippy::await_holding_lock)]
        let result = TOKIO_RUNTIME.block_on(async {
            let client_guard = safe_lock_arc(&client, "execute_transactional_batch_native client")?;
            let conn_guard = safe_lock_arc(
                &client_guard.client,
                "execute_transactional_batch_native conn",
            )?;
            let mut batch_rows =
                conn_guard
                    .execute_transactional_batch(sql)
                    .await
                    .map_err(|e| {
                        rustler::Error::Term(Box::new(format!("transactional batch failed: {e}")))
                    })?;
            // Drop guards after batch is retrieved
            drop(conn_guard);
            drop(client_guard);

            // Collect all results
            let mut results: Vec<Term<'a>> = Vec::new();
            while let Some(maybe_rows) = batch_rows.next_stmt_row() {
                match maybe_rows {
                    Some(rows) => {
                        let collected = collect_rows(env, rows).await?;
                        results.push(collected);
                    }
                    None => {
                        results.push(nil().encode(env));
                    }
                }
            }

            Ok::<Term<'a>, rustler::Error>(results.encode(env))
        });

        result
    } else {
        Err(rustler::Error::Term(Box::new("Invalid connection ID")))
    }
}
