/// Transaction management for LibSQL databases.
///
/// This module handles database transactions, including:
/// - Starting transactions with configurable locking behavior
/// - Executing queries and statements within transactions
/// - Committing or rolling back transactions
/// - Transaction ownership verification
///
/// Transactions are tracked via a registry and identified by transaction IDs.
/// Each transaction is associated with a connection ID to prevent cross-connection misuse.
///
/// **Note on Locking**: Some functions hold Arc<Mutex<>> locks across await points in async blocks.
/// This is necessary because `libsql::Connection` methods return futures that borrow from the guard.
/// The pattern is safe because we use `TOKIO_RUNTIME.block_on()` which executes the entire
/// async block on a dedicated thread pool, preventing deadlocks.
use crate::{
    constants::{CONNECTION_REGISTRY, TOKIO_RUNTIME, TXN_REGISTRY},
    decode,
    models::TransactionEntry,
    utils,
};
use rustler::{Atom, Env, NifResult, Term};
use std::sync::MutexGuard;

/// RAII guard for transaction entry management.
///
/// This guard encapsulates the "remove → verify → async → re-insert" pattern
/// used throughout the codebase. It guarantees re-insertion of the transaction
/// entry on all paths (success, error, and panic) unless explicitly consumed.
///
/// The guard tracks whether it has been consumed to prevent double-consumption
/// or use-after-consume errors, returning proper `Result` errors instead of panicking.
///
/// # Usage
///
/// ```ignore
/// // Standard pattern (re-inserts on drop)
/// let guard = TransactionEntryGuard::take(trx_id, conn_id)?;
/// let result = TOKIO_RUNTIME.block_on(async {
///     guard.transaction()?.execute(&query, args).await
/// });
/// // Guard automatically re-inserts the entry here
/// result.map_err(...)
/// ```
///
/// ```ignore
/// // Consume pattern (for commit/rollback - no re-insertion)
/// let guard = TransactionEntryGuard::take(trx_id, conn_id)?;
/// let entry = guard.consume()?;
/// // ... commit or rollback the entry
/// // Entry is NOT re-inserted
/// ```
///
/// # Internal Use Only
///
/// This guard is for internal use within the NIF implementation and assumes
/// correct usage patterns (transaction() and consume() called at most once).
pub struct TransactionEntryGuard {
    trx_id: String,
    entry: Option<TransactionEntry>,
    consumed: bool,
}

impl TransactionEntryGuard {
    /// Remove entry from registry and verify ownership.
    ///
    /// Returns an error if:
    /// - The transaction is not found
    /// - The transaction does not belong to the specified connection
    ///
    /// On ownership verification failure, the entry is automatically re-inserted
    /// before returning the error.
    pub fn take(trx_id: &str, conn_id: &str) -> Result<Self, rustler::Error> {
        let mut txn_registry = utils::safe_lock(&TXN_REGISTRY, "TransactionEntryGuard::take")?;

        let entry = txn_registry
            .remove(trx_id)
            .ok_or_else(|| rustler::Error::Term(Box::new("Transaction not found")))?;

        // Verify ownership
        if entry.conn_id != conn_id {
            // Re-insert before returning error
            txn_registry.insert(trx_id.to_string(), entry);
            return Err(rustler::Error::Term(Box::new(
                "Transaction does not belong to this connection",
            )));
        }

        Ok(Self {
            trx_id: trx_id.to_string(),
            entry: Some(entry),
            consumed: false,
        })
    }

    /// Get a reference to the transaction.
    ///
    /// Returns an error if the entry has already been consumed via `consume()`.
    /// This provides defensive error handling instead of panicking.
    pub fn transaction(&self) -> Result<&libsql::Transaction, rustler::Error> {
        if self.consumed {
            return Err(rustler::Error::Term(Box::new(
                "Transaction entry already consumed",
            )));
        }

        self.entry
            .as_ref()
            .map(|e| &e.transaction)
            .ok_or_else(|| rustler::Error::Term(Box::new("Transaction entry is missing")))
    }

    /// Consume the guard without re-inserting the entry.
    ///
    /// This is used for commit/rollback operations where the transaction
    /// should not be re-inserted into the registry.
    ///
    /// Returns an error if the entry has already been consumed, preventing
    /// misuse and allowing proper error handling instead of panicking.
    pub fn consume(mut self) -> Result<TransactionEntry, rustler::Error> {
        if self.consumed {
            return Err(rustler::Error::Term(Box::new(
                "Transaction entry already consumed",
            )));
        }

        // Mark as consumed so Drop won't try to re-insert
        self.consumed = true;

        self.entry
            .take()
            .ok_or_else(|| rustler::Error::Term(Box::new("Transaction entry is missing")))
    }
}

impl Drop for TransactionEntryGuard {
    /// Automatically re-insert the transaction entry if not consumed.
    ///
    /// This ensures the entry is always re-inserted on all paths (including
    /// error returns and panics) unless explicitly consumed via `consume()`.
    fn drop(&mut self) {
        if let Some(entry) = self.entry.take() {
            // Best-effort re-insertion. If the lock fails during drop,
            // we're likely in a panic or shutdown scenario.
            if let Ok(mut registry) = utils::safe_lock(&TXN_REGISTRY, "TransactionEntryGuard::drop")
            {
                registry.insert(self.trx_id.clone(), entry);
            }
        }
    }
}

/// Begin a new database transaction.
///
/// Starts a transaction with the default DEFERRED behavior, which acquires
/// locks only when needed. Use `begin_transaction_with_behavior` for fine-grained
/// control over transaction locking.
///
/// # Arguments
/// - `conn_id`: Database connection ID
///
/// Returns a transaction ID on success, error on failure.
#[rustler::nif(schedule = "DirtyIo")]
pub fn begin_transaction(conn_id: &str) -> NifResult<String> {
    let conn_map = utils::safe_lock(&CONNECTION_REGISTRY, "begin_transaction conn_map")?;
    let client = conn_map
        .get(conn_id)
        .cloned()
        .ok_or_else(|| rustler::Error::Term(Box::new("Invalid connection ID")))?;
    drop(conn_map); // Drop lock before async operation

    // Clone the inner connection Arc and drop the outer lock before async operations
    let connection = {
        let client_guard = utils::safe_lock_arc(&client, "begin_transaction client")?;
        client_guard.client.clone()
    }; // Outer lock dropped here

    // SAFETY: We use TOKIO_RUNTIME.block_on(), which runs the future synchronously on a dedicated
    // thread pool. This prevents deadlocks that could occur if we were in a true async context
    // with std::sync::Mutex guards held across await points.
    #[allow(clippy::await_holding_lock)]
    let trx = TOKIO_RUNTIME.block_on(async {
        // Lock must be held across await because transaction() returns a Future that
        // borrows from the Connection. We cannot drop the guard before awaiting.
        let conn_guard = utils::safe_lock_arc(&connection, "begin_transaction conn")?;
        conn_guard
            .transaction()
            .await
            .map_err(|e| rustler::Error::Term(Box::new(format!("Begin failed: {e}"))))
    })?;

    let trx_id = uuid::Uuid::new_v4().to_string();
    let entry = TransactionEntry {
        conn_id: conn_id.to_string(),
        transaction: trx,
    };
    utils::safe_lock(&TXN_REGISTRY, "begin_transaction txn_registry")?
        .insert(trx_id.clone(), entry);

    Ok(trx_id)
}

/// Begin a new database transaction with specific locking behavior.
///
/// Allows control over how aggressively the transaction acquires locks:
/// - `:deferred` - Acquire locks only when needed (default, recommended)
/// - `:immediate` - Acquire write lock immediately
/// - `:exclusive` - Exclusive lock, blocks all other connections
/// - `:read_only` - No locks, read-only operation
///
/// # Arguments
/// - `conn_id`: Database connection ID
/// - `behavior`: Transaction behavior atom
///
/// Returns a transaction ID on success, error on failure.
#[rustler::nif(schedule = "DirtyIo")]
pub fn begin_transaction_with_behavior(conn_id: &str, behavior: Atom) -> NifResult<String> {
    let trx_behavior = match decode::decode_transaction_behavior(behavior) {
        Some(b) => b,
        None => {
            // Unrecognized behavior - return error to Elixir for proper logging
            // This allows the application to handle unknown behaviors explicitly
            return Err(rustler::Error::Term(Box::new(
                format!("Invalid transaction behavior: {behavior:?}. Use :deferred, :immediate, :exclusive, or :read_only")
            )));
        }
    };

    let conn_map = utils::safe_lock(
        &CONNECTION_REGISTRY,
        "begin_transaction_with_behavior conn_map",
    )?;
    let client = conn_map
        .get(conn_id)
        .cloned()
        .ok_or_else(|| rustler::Error::Term(Box::new("Invalid connection ID")))?;
    drop(conn_map); // Drop lock before async operation

    // Clone the inner connection Arc and drop the outer lock before async operations
    let connection = {
        let client_guard = utils::safe_lock_arc(&client, "begin_transaction_with_behavior client")?;
        client_guard.client.clone()
    }; // Outer lock dropped here

    // SAFETY: We use TOKIO_RUNTIME.block_on(), which runs the future synchronously on a dedicated
    // thread pool. This prevents deadlocks that could occur if we were in a true async context
    // with std::sync::Mutex guards held across await points.
    #[allow(clippy::await_holding_lock)]
    let trx = TOKIO_RUNTIME.block_on(async {
        // Lock must be held across await because transaction_with_behavior() returns a Future
        // that borrows from the Connection. We cannot drop the guard before awaiting.
        let conn_guard = utils::safe_lock_arc(&connection, "begin_transaction_with_behavior conn")?;
        conn_guard
            .transaction_with_behavior(trx_behavior)
            .await
            .map_err(|e| rustler::Error::Term(Box::new(format!("Begin failed: {e}"))))
    })?;

    let trx_id = uuid::Uuid::new_v4().to_string();
    let entry = TransactionEntry {
        conn_id: conn_id.to_string(),
        transaction: trx,
    };
    utils::safe_lock(
        &TXN_REGISTRY,
        "begin_transaction_with_behavior txn_registry",
    )?
    .insert(trx_id.clone(), entry);

    Ok(trx_id)
}

/// Execute a SQL statement within a transaction without returning rows.
///
/// Use this for INSERT, UPDATE, DELETE statements within a transaction.
/// For statements that return rows, use `query_with_trx_args` instead.
///
/// Returns the number of affected rows.
///
/// # Arguments
/// - `trx_id`: Transaction ID
/// - `conn_id`: Connection ID (for ownership verification)
/// - `query`: SQL query string
/// - `args`: Query parameters
#[rustler::nif(schedule = "DirtyIo")]
pub fn execute_with_transaction<'a>(
    trx_id: &str,
    conn_id: &str,
    query: &str,
    args: Vec<Term<'a>>,
) -> NifResult<u64> {
    // Decode args before locking
    let decoded_args: Vec<libsql::Value> = args
        .into_iter()
        .map(|t| utils::decode_term_to_value(t))
        .collect::<Result<_, _>>()
        .map_err(|e| rustler::Error::Term(Box::new(e)))?;

    // Take transaction entry with ownership verification
    let guard = TransactionEntryGuard::take(trx_id, conn_id)?;

    // Get transaction reference (already returns rustler::Error on failure)
    let trx = guard.transaction()?;

    let result = TOKIO_RUNTIME
        .block_on(async { trx.execute(query, decoded_args).await })
        .map_err(|e| rustler::Error::Term(Box::new(format!("Execute failed: {e}"))));
    // Guard automatically re-inserts the entry on drop
    result
}

/// Execute a SQL query within a transaction that returns rows.
///
/// Use this for SELECT statements or INSERT/UPDATE/DELETE with RETURNING clause
/// within a transaction. For statements that don't return rows, use
/// `execute_with_transaction` instead.
///
/// # Arguments
/// - `env`: Elixir environment
/// - `trx_id`: Transaction ID
/// - `conn_id`: Connection ID (for ownership verification)
/// - `query`: SQL query string
/// - `args`: Query parameters
#[rustler::nif(schedule = "DirtyIo")]
pub fn query_with_trx_args<'a>(
    env: Env<'a>,
    trx_id: &str,
    conn_id: &str,
    query: &str,
    args: Vec<Term<'a>>,
) -> NifResult<Term<'a>> {
    // Decode args before locking
    let decoded_args: Vec<libsql::Value> = args
        .into_iter()
        .map(|t| utils::decode_term_to_value(t))
        .collect::<Result<_, _>>()
        .map_err(|e| rustler::Error::Term(Box::new(e)))?;

    // Determine whether to use query() or execute() based on statement
    let use_query = utils::should_use_query(query);

    // Take transaction entry with ownership verification
    let guard = TransactionEntryGuard::take(trx_id, conn_id)?;

    // Get transaction reference (already returns rustler::Error on failure)
    let trx = guard.transaction()?;

    // Get connection for error enhancement
    let connection = {
        let conn_map = utils::safe_lock(&CONNECTION_REGISTRY, "query_with_trx_args conn_map")?;
        let client = conn_map
            .get(conn_id)
            .ok_or_else(|| rustler::Error::Term(Box::new("Connection not found")))?;
        let client_guard = utils::safe_lock_arc(client, "query_with_trx_args client")?;
        client_guard.client.clone()
    };

    // Execute async operation without holding the lock
    // SAFETY: We use TOKIO_RUNTIME.block_on(), which runs the future synchronously on a dedicated
    // thread pool. This prevents deadlocks that could occur if we were in a true async context
    // with std::sync::Mutex guards held across await points.
    #[allow(clippy::await_holding_lock)]
    let result = TOKIO_RUNTIME.block_on(async {
        if use_query {
            // Statements that return rows (SELECT, or INSERT/UPDATE/DELETE with RETURNING)
            let res = trx.query(query, decoded_args).await;

            match res {
                Ok(res_rows) => utils::collect_rows(env, res_rows).await,
                Err(e) => {
                    let error_msg = format!("Query failed: {e}");
                    // safe_lock_arc already returns rustler::Error with good context
                    let conn_guard: MutexGuard<libsql::Connection> =
                        utils::safe_lock_arc(&connection, "query_with_trx_args conn for error")?;
                    let enhanced_msg = utils::enhance_constraint_error(&conn_guard, &error_msg)
                        .await
                        .unwrap_or(error_msg);
                    Err(rustler::Error::Term(Box::new(enhanced_msg)))
                }
            }
        } else {
            // Statements that don't return rows (INSERT/UPDATE/DELETE without RETURNING)
            let res = trx.execute(query, decoded_args).await;

            match res {
                Ok(rows_affected) => Ok(utils::build_empty_result(env, rows_affected)),
                Err(e) => {
                    let error_msg = format!("Execute failed: {e}");
                    // safe_lock_arc already returns rustler::Error with good context
                    let conn_guard: MutexGuard<libsql::Connection> =
                        utils::safe_lock_arc(&connection, "query_with_trx_args conn for error")?;
                    let enhanced_msg = utils::enhance_constraint_error(&conn_guard, &error_msg)
                        .await
                        .unwrap_or(error_msg);
                    Err(rustler::Error::Term(Box::new(enhanced_msg)))
                }
            }
        }
    });

    // Guard automatically re-inserts the entry on drop

    result
}

/// Check if a transaction is still active in the transaction registry.
///
/// Returns `:ok` if the transaction exists, error otherwise.
#[rustler::nif(schedule = "DirtyIo")]
pub fn handle_status_transaction(trx_id: &str) -> NifResult<Atom> {
    let trx_registry = utils::safe_lock(&TXN_REGISTRY, "handle_status_transaction")?;
    let trx = trx_registry.get(trx_id);

    match trx {
        Some(_) => Ok(rustler::types::atom::ok()),
        None => Err(rustler::Error::Term(Box::new("Transaction not found"))),
    }
}

/// Commit or rollback a transaction.
///
/// The `param` argument determines the action:
/// - `"commit"` - Commit the transaction
/// - `"rollback"` - Rollback the transaction
///
/// After commit or rollback, the transaction is removed from the registry.
///
/// # Arguments
/// - `trx_id`: Transaction ID
/// - `conn_id`: Connection ID (for ownership verification)
/// - `mode`: Connection mode (unused, for API compatibility)
/// - `syncx`: Sync mode (unused, automatic sync is handled by LibSQL)
/// - `param`: Action to perform ("commit" or "rollback")
#[rustler::nif(schedule = "DirtyIo")]
pub fn commit_or_rollback_transaction(
    trx_id: &str,
    conn_id: &str,
    _mode: Atom,
    _syncx: Atom,
    param: &str,
) -> NifResult<(Atom, String)> {
    // Take transaction entry with ownership verification
    let guard = TransactionEntryGuard::take(trx_id, conn_id)?;

    // Consume the entry (we don't want to re-insert after commit/rollback)
    let entry = guard.consume()?;

    let result = TOKIO_RUNTIME.block_on(async {
        if param == "commit" {
            entry
                .transaction
                .commit()
                .await
                .map_err(|e| format!("Commit error: {e}"))?;
        } else {
            entry
                .transaction
                .rollback()
                .await
                .map_err(|e| format!("Rollback error: {e}"))?;
        }

        // NOTE: LibSQL automatically syncs transaction commits to remote for embedded replicas.
        // No manual sync needed here.

        Ok::<_, String>(())
    });

    match result {
        Ok(()) => Ok((rustler::types::atom::ok(), format!("{param} success"))),
        Err(e) => Err(rustler::Error::Term(Box::new(format!(
            "TOKIO_RUNTIME ERR {e}"
        )))),
    }
}
