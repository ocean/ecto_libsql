/// Savepoint management for nested transactions
///
/// This module handles savepoints within transactions, allowing partial rollback
/// without aborting the entire transaction. Savepoints provide a way to create
/// checkpoints within a transaction that can be rolled back to independently.
use crate::constants::*;
use crate::decode::validate_savepoint_name;
use crate::transaction::TransactionEntryGuard;
use libsql::Value;
use rustler::{Atom, NifResult};

/// Create a savepoint within a transaction.
///
/// Savepoints allow partial rollback without aborting the entire transaction.
/// You can create multiple savepoints and rollback to any of them.
///
/// **Security**: Validates that the transaction belongs to the requesting connection
/// to prevent cross-connection access.
///
/// # Arguments
/// - `conn_id`: Database connection ID (for ownership validation)
/// - `trx_id`: Transaction ID
/// - `name`: Savepoint name (must be a valid SQL identifier)
///
/// # Savepoint Name Rules
/// - Must not be empty
/// - Must contain only ASCII alphanumeric characters and underscores
/// - Must not start with a digit
///
/// Returns `:ok` on success, error on failure.
#[rustler::nif(schedule = "DirtyIo")]
pub fn savepoint(conn_id: &str, trx_id: &str, name: &str) -> NifResult<Atom> {
    validate_savepoint_name(name)?;

    // Take transaction entry with ownership verification using guard
    let guard = TransactionEntryGuard::take(trx_id, conn_id)?;

    let sql = format!("SAVEPOINT {name}");

    TOKIO_RUNTIME.block_on(async {
        guard
            .transaction()?
            .execute(&sql, Vec::<Value>::new())
            .await
            .map_err(|e| rustler::Error::Term(Box::new(format!("Savepoint failed: {e}"))))
    })?;

    // Guard automatically re-inserts the transaction on drop
    Ok(rustler::types::atom::ok())
}

/// Release (commit) a savepoint, making its changes permanent within the transaction.
///
/// Releasing a savepoint removes it and makes all changes since the savepoint permanent
/// within the transaction (though still subject to the final transaction commit/rollback).
///
/// **Security**: Validates that the transaction belongs to the requesting connection.
///
/// # Arguments
/// - `conn_id`: Database connection ID (for ownership validation)
/// - `trx_id`: Transaction ID
/// - `name`: Savepoint name to release
///
/// Returns `:ok` on success, error on failure.
#[rustler::nif(schedule = "DirtyIo")]
pub fn release_savepoint(conn_id: &str, trx_id: &str, name: &str) -> NifResult<Atom> {
    validate_savepoint_name(name)?;

    // Take transaction entry with ownership verification using guard
    let guard = TransactionEntryGuard::take(trx_id, conn_id)?;

    let sql = format!("RELEASE SAVEPOINT {name}");

    TOKIO_RUNTIME.block_on(async {
        guard
            .transaction()?
            .execute(&sql, Vec::<Value>::new())
            .await
            .map_err(|e| rustler::Error::Term(Box::new(format!("Release savepoint failed: {e}"))))
    })?;

    // Guard automatically re-inserts the transaction on drop
    Ok(rustler::types::atom::ok())
}

/// Rollback to a savepoint, undoing all changes made after the savepoint was created.
///
/// The savepoint remains active after rollback and can be released or rolled back to again.
/// This allows for retry patterns within a transaction.
///
/// **Security**: Validates that the transaction belongs to the requesting connection.
///
/// # Arguments
/// - `conn_id`: Database connection ID (for ownership validation)
/// - `trx_id`: Transaction ID
/// - `name`: Savepoint name to rollback to
///
/// Returns `:ok` on success, error on failure.
#[rustler::nif(schedule = "DirtyIo")]
pub fn rollback_to_savepoint(conn_id: &str, trx_id: &str, name: &str) -> NifResult<Atom> {
    validate_savepoint_name(name)?;

    // Take transaction entry with ownership verification using guard
    let guard = TransactionEntryGuard::take(trx_id, conn_id)?;

    let sql = format!("ROLLBACK TO SAVEPOINT {name}");

    TOKIO_RUNTIME.block_on(async {
        guard
            .transaction()?
            .execute(&sql, Vec::<Value>::new())
            .await
            .map_err(|e| {
                rustler::Error::Term(Box::new(format!("Rollback to savepoint failed: {e}")))
            })
    })?;

    // Guard automatically re-inserts the transaction on drop
    Ok(rustler::types::atom::ok())
}
