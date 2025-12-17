/// Data structures and resource definitions for EctoLibSql
///
/// This module defines the core data types used throughout the NIF implementation,
/// including connection wrappers, transaction entries, and cursor state.
use libsql::{Transaction, Value};
use rustler::Resource;
use std::sync::Arc;

/// LibSQL connection wrapper - resource passed to Elixir
///
/// Contains both the database and an active connection.
/// Wrapped in Arc<Mutex<>> for thread-safe shared access across the connection pool.
#[derive(Debug)]
pub struct LibSQLConn {
    /// The LibSQL database instance
    pub db: libsql::Database,
    /// An active connection to the database
    pub client: Arc<std::sync::Mutex<libsql::Connection>>,
}

/// Resource implementation for LibSQLConn
/// This allows Elixir to hold references to Rust LibSQLConn instances
impl Resource for LibSQLConn {}

/// Cursor state for streaming result sets
///
/// Holds result data and position for cursor-based iteration through large result sets.
#[derive(Debug)]
pub struct CursorData {
    /// Connection ID that owns this cursor
    pub conn_id: String,
    /// Column names from the query
    pub columns: Vec<String>,
    /// All rows returned by the query
    pub rows: Vec<Vec<Value>>,
    /// Current position in the result set
    pub position: usize,
}

/// Transaction entry with ownership tracking
///
/// Tracks which connection owns a transaction and holds the transaction reference.
pub struct TransactionEntry {
    /// Connection ID that created this transaction
    pub conn_id: String,
    /// The actual transaction object
    pub transaction: Transaction,
}

/// Connection mode enumeration
///
/// Determines how the connection is established and what capabilities are available.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// Local SQLite database file
    Local,
    /// Direct connection to remote LibSQL/Turso server
    Remote,
    /// Local replica with remote sync
    RemoteReplica,
}
