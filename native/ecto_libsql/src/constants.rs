/// Global constants and atom declarations for EctoLibSql
///
/// This module holds all static configuration, global registries, and atom definitions
/// used throughout the codebase.
use rustler::atoms;
use std::collections::HashMap;
use std::sync::{Arc, LazyLock, Mutex};
use tokio::runtime::Runtime;

use crate::models::{CursorData, LibSQLConn, TransactionEntry};

/// Type alias to reduce complexity of the statement registry
type StatementEntry = (String, Arc<Mutex<libsql::Statement>>);

/// Global Tokio runtime for async operations
///
/// IMPORTANT: This panics if Tokio runtime creation fails, which can only happen in
/// extremely rare circumstances (e.g., system has no available threads). In normal
/// operation, runtime creation succeeds immediately on the first NIF call.
///
/// If you see "Failed to initialize Tokio runtime" panics, check:
/// - System has available threads
/// - Ulimit settings (-u) are not too restrictive
/// - System memory is available
#[allow(clippy::expect_used)] // Intentional: runtime creation must succeed or the NIF cannot function
pub static TOKIO_RUNTIME: LazyLock<Runtime> = LazyLock::new(|| {
    Runtime::new()
        .expect("Failed to initialize Tokio runtime - check system resources and thread limits")
});

/// Default timeout for sync operations (in seconds)
pub const DEFAULT_SYNC_TIMEOUT_SECS: u64 = 30;

/// Global registry for active database connections
///
/// Maps connection ID to `LibSQLConn` state wrapped in `Arc<Mutex>` for thread-safe access.
pub static CONNECTION_REGISTRY: LazyLock<Mutex<HashMap<String, Arc<Mutex<LibSQLConn>>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// Global registry for active transactions
///
/// Maps transaction ID to `TransactionEntry` containing the connection ownership info.
pub static TXN_REGISTRY: LazyLock<Mutex<HashMap<String, TransactionEntry>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// Global registry for prepared statements
///
/// Maps statement ID to (connection_id, cached_statement) tuple.
pub static STMT_REGISTRY: LazyLock<Mutex<HashMap<String, StatementEntry>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// Global registry for active cursors
///
/// Maps cursor ID to `CursorData` containing buffered rows and position.
pub static CURSOR_REGISTRY: LazyLock<Mutex<HashMap<String, CursorData>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

// Atom declarations for EctoLibSql - used as return values and option identifiers in the NIF interface
atoms! {
    local,
    remote,
    remote_replica,
    ok,
    error,
    conn_id,
    trx_id,
    stmt_id,
    cursor_id,
    disable_sync,
    enable_sync,
    deferred,
    immediate,
    exclusive,
    read_only,
    transaction,
    connection,
    blob,
    nil,
    unsupported
}
