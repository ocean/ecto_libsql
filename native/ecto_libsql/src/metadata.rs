/// Database metadata and introspection functions
///
/// This module provides functions to query database metadata and state information,
/// such as the number of affected rows, last inserted row IDs, and autocommit mode.
use crate::constants::*;
use crate::utils::{safe_lock, safe_lock_arc};
use rustler::NifResult;

/// Get the rowid of the last inserted row in the current connection.
///
/// In SQLite, every row has an implicit `rowid` column (unless WITHOUT ROWID is used).
/// This function returns the rowid of the most recently inserted row, which is useful
/// for retrieving auto-generated IDs.
///
/// Returns 0 if no inserts have occurred in this session.
///
/// # Arguments
/// - `conn_id`: Database connection ID
///
/// # Examples
/// ```elixir
/// {:ok, _} = EctoLibSql.execute("INSERT INTO users (name) VALUES (?)", ["Alice"])
/// rowid = EctoLibSql.last_insert_rowid(conn_id)  # Returns the ID of the inserted user
/// ```
#[rustler::nif(schedule = "DirtyIo")]
pub fn last_insert_rowid(conn_id: &str) -> NifResult<i64> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "last_insert_rowid conn_map")?;

    if let Some(client) = conn_map.get(conn_id) {
        let client = client.clone();
        drop(conn_map); // Release lock before async operation

        let result = TOKIO_RUNTIME.block_on(async {
            let client_guard = safe_lock_arc(&client, "last_insert_rowid client")?;
            let conn_guard = safe_lock_arc(&client_guard.client, "last_insert_rowid conn")?;

            Ok::<i64, rustler::Error>(conn_guard.last_insert_rowid())
        })?;

        Ok(result)
    } else {
        Err(rustler::Error::Term(Box::new("Invalid connection ID")))
    }
}

/// Get the number of rows affected by the last statement execution.
///
/// This returns the number of rows modified by the most recent INSERT, UPDATE, or DELETE
/// statement. For SELECT statements or other statements that don't modify data, returns 0.
///
/// Useful for verifying that the expected number of rows were affected by DML operations.
///
/// # Arguments
/// - `conn_id`: Database connection ID
///
/// # Examples
/// ```elixir
/// {:ok, _} = EctoLibSql.execute("UPDATE users SET active = 1 WHERE age > 18")
/// changes = EctoLibSql.changes(conn_id)  # Returns number of updated rows
/// ```
#[rustler::nif(schedule = "DirtyIo")]
pub fn changes(conn_id: &str) -> NifResult<u64> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "changes conn_map")?;

    if let Some(client) = conn_map.get(conn_id) {
        let client = client.clone();
        drop(conn_map); // Release lock before async operation

        let result = TOKIO_RUNTIME.block_on(async {
            let client_guard = safe_lock_arc(&client, "changes client")?;
            let conn_guard = safe_lock_arc(&client_guard.client, "changes conn")?;

            Ok::<u64, rustler::Error>(conn_guard.changes())
        })?;

        Ok(result)
    } else {
        Err(rustler::Error::Term(Box::new("Invalid connection ID")))
    }
}

/// Get the total number of rows affected since this connection was opened.
///
/// Unlike `changes()` which returns only the last statement's impact, this returns
/// the cumulative total of all rows modified (INSERT, UPDATE, DELETE) since the
/// connection was established.
///
/// This is useful for connection-level metrics and monitoring.
///
/// # Arguments
/// - `conn_id`: Database connection ID
///
/// # Examples
/// ```elixir
/// total = EctoLibSql.total_changes(conn_id)  # Cumulative rows affected
/// ```
#[rustler::nif(schedule = "DirtyIo")]
pub fn total_changes(conn_id: &str) -> NifResult<u64> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "total_changes conn_map")?;

    if let Some(client) = conn_map.get(conn_id) {
        let client = client.clone();
        drop(conn_map); // Release lock before async operation

        let result = TOKIO_RUNTIME.block_on(async {
            let client_guard = safe_lock_arc(&client, "total_changes client")?;
            let conn_guard = safe_lock_arc(&client_guard.client, "total_changes conn")?;

            Ok::<u64, rustler::Error>(conn_guard.total_changes())
        })?;

        Ok(result)
    } else {
        Err(rustler::Error::Term(Box::new("Invalid connection ID")))
    }
}

/// Check if the connection is in autocommit mode.
///
/// SQLite starts in autocommit mode by default, where each statement is committed
/// immediately unless inside an explicit transaction.
///
/// Returns `true` if in autocommit mode, `false` if inside a transaction.
///
/// # Arguments
/// - `conn_id`: Database connection ID
///
/// # Examples
/// ```elixir
/// is_auto = EctoLibSql.is_autocommit(conn_id)  # Returns true outside transactions
/// ```
#[rustler::nif(schedule = "DirtyIo")]
pub fn is_autocommit(conn_id: &str) -> NifResult<bool> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "is_autocommit conn_map")?;

    if let Some(client) = conn_map.get(conn_id) {
        let client = client.clone();
        drop(conn_map); // Release lock before async operation

        let result = TOKIO_RUNTIME.block_on(async {
            let client_guard = safe_lock_arc(&client, "is_autocommit client")?;
            let conn_guard = safe_lock_arc(&client_guard.client, "is_autocommit conn")?;

            Ok::<bool, rustler::Error>(conn_guard.is_autocommit())
        })?;

        Ok(result)
    } else {
        Err(rustler::Error::Term(Box::new("Invalid connection ID")))
    }
}
