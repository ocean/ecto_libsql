/// Connection lifecycle management for LibSQL/Turso databases
///
/// This module handles database connection establishment, health checking,
/// and connection state management including cleanup and timeouts.
use crate::constants::*;
use crate::decode;
use crate::models::{LibSQLConn, Mode};
use crate::utils::safe_lock_arc;
use bytes::Bytes;
use libsql::{Builder, Cipher, EncryptionConfig};
use rustler::{Atom, NifResult, Term};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use uuid::Uuid;

/// Establish a database connection to a local, remote, or remote replica database.
///
/// Supports three connection modes:
/// - **local**: Direct connection to a local SQLite file
/// - **remote**: Direct connection to a remote LibSQL/Turso server
/// - **remote_replica**: Local replica with automatic sync to remote
///
/// Connection parameters are passed as Elixir keyword list:
/// - `database` - Path to local database file (required for local/remote_replica modes)
/// - `uri` - Remote database URI (required for remote/remote_replica modes)
/// - `auth_token` - Authentication token (required for remote/remote_replica modes)
/// - `encryption_key` - Optional encryption key (min 32 chars) for encryption at rest
///
/// Returns the connection ID as a string on success, or an error on failure.
///
/// **Timeouts**: Connection establishment has a 30-second timeout to prevent hanging.
#[rustler::nif(schedule = "DirtyIo")]
pub fn connect(opts: Term, mode: Term) -> NifResult<String> {
    let list: Vec<Term> = opts
        .decode()
        .map_err(|e| rustler::Error::Term(Box::new(format!("decode failed: {:?}", e))))?;

    let mut map = HashMap::with_capacity(list.len());

    for pair in list {
        let (key, value): (rustler::Atom, Term) = pair.decode().map_err(|e| {
            rustler::Error::Term(Box::new(format!("expected keyword tuple: {:?}", e)))
        })?;
        map.insert(format!("{:?}", key), value);
    }

    let url = map.get("uri").and_then(|t| t.decode::<String>().ok());
    let token = map
        .get("auth_token")
        .and_then(|t| t.decode::<String>().ok());
    let dbname = map.get("database").and_then(|t| t.decode::<String>().ok());
    let encryption_key = map
        .get("encryption_key")
        .and_then(|t| t.decode::<String>().ok());

    // Wrap the entire connection process with a timeout using the global runtime.
    TOKIO_RUNTIME.block_on(async {
        let timeout = Duration::from_secs(DEFAULT_SYNC_TIMEOUT_SECS);

        tokio::time::timeout(timeout, async {
            let mode_atom: Atom = mode
                .decode()
                .map_err(|_| rustler::Error::Term(Box::new("Invalid mode atom")))?;

            let mode_enum = decode::decode_mode(mode_atom)
                .ok_or_else(|| rustler::Error::Term(Box::new("Unknown mode")))?;

            let db = match mode_enum {
                Mode::RemoteReplica => {
                    let url = url.ok_or_else(|| rustler::Error::BadArg)?;
                    let token = token.ok_or_else(|| rustler::Error::BadArg)?;
                    let dbname = dbname.ok_or_else(|| rustler::Error::BadArg)?;

                    let mut builder = Builder::new_remote_replica(dbname, url, token);

                    if let Some(key) = encryption_key {
                        let config = EncryptionConfig {
                            cipher: Cipher::Aes256Cbc,
                            encryption_key: Bytes::from(key),
                        };
                        builder = builder.encryption_config(config);
                    }

                    builder.build().await
                }
                Mode::Remote => {
                    let url = url.ok_or_else(|| rustler::Error::BadArg)?;
                    let token = token.ok_or_else(|| rustler::Error::BadArg)?;

                    Builder::new_remote(url, token).build().await
                }
                Mode::Local => {
                    let dbname = dbname.ok_or_else(|| rustler::Error::BadArg)?;

                    let mut builder = Builder::new_local(dbname);

                    if let Some(key) = encryption_key {
                        let config = EncryptionConfig {
                            cipher: Cipher::Aes256Cbc,
                            encryption_key: Bytes::from(key),
                        };
                        builder = builder.encryption_config(config);
                    }

                    builder.build().await
                }
            }
            .map_err(|e| rustler::Error::Term(Box::new(format!("Failed to build DB: {}", e))))?;

            let conn = db
                .connect()
                .map_err(|e| rustler::Error::Term(Box::new(format!("Failed to connect: {}", e))))?;

            // Ping remote connections to verify they're accessible
            if mode_enum != Mode::Local {
                conn.query("SELECT 1", ())
                    .await
                    .map_err(|e| rustler::Error::Term(Box::new(format!("Failed ping: {}", e))))?;
            }

            let libsql_conn = Arc::new(Mutex::new(LibSQLConn {
                db,
                client: Arc::new(Mutex::new(conn)),
            }));

            let conn_id = Uuid::new_v4().to_string();
            crate::utils::safe_lock(&CONNECTION_REGISTRY, "connect conn_registry")
                .map_err(|e| {
                    rustler::Error::Term(Box::new(format!(
                        "Failed to register connection: {:?}",
                        e
                    )))
                })?
                .insert(conn_id.clone(), libsql_conn);

            Ok(conn_id)
        })
        .await
        .map_err(|_| {
            rustler::Error::Term(Box::new(format!(
                "Connection timeout after {} seconds",
                DEFAULT_SYNC_TIMEOUT_SECS
            )))
        })?
    })
}

/// Check if a database connection is alive and responsive.
///
/// Performs a simple `SELECT 1` query to verify the connection is working.
/// Returns `true` if the connection is healthy, error otherwise.
#[rustler::nif(schedule = "DirtyIo")]
pub fn ping(conn_id: String) -> NifResult<bool> {
    let conn_map = crate::utils::safe_lock(&CONNECTION_REGISTRY, "ping conn_map")?;

    let maybe_conn = conn_map.get(&conn_id);
    if let Some(conn) = maybe_conn {
        let client = conn.clone();
        drop(conn_map); // Release lock before async operation

        let result = TOKIO_RUNTIME.block_on(async {
            let client_guard =
                safe_lock_arc(&client, "ping client").map_err(|e| format!("{:?}", e))?;
            let conn_guard: std::sync::MutexGuard<libsql::Connection> =
                safe_lock_arc(&client_guard.client, "ping conn").map_err(|e| format!("{:?}", e))?;

            conn_guard
                .query("SELECT 1", ())
                .await
                .map_err(|e| format!("{:?}", e))
        });
        match result {
            Ok(_) => Ok(true),
            Err(e) => Err(rustler::Error::Term(Box::new(format!(
                "Ping error: {:?}",
                e
            )))),
        }
    } else {
        Err(rustler::Error::Term(Box::new("Invalid connection ID")))
    }
}

/// Close a resource (connection, transaction, statement, or cursor).
///
/// The `opt` parameter specifies which type of resource to close:
/// - `:conn_id` - Close a database connection
/// - `:trx_id` - Close/forget a transaction
/// - `:stmt_id` - Close a prepared statement
/// - `:cursor_id` - Close a cursor
///
/// Returns `:ok` on success, error if the resource ID is not found.
#[rustler::nif(schedule = "DirtyIo")]
pub fn close(id: &str, opt: Atom) -> NifResult<Atom> {
    if opt == conn_id() {
        let removed = crate::utils::safe_lock(&CONNECTION_REGISTRY, "close conn")?.remove(id);
        match removed {
            Some(_) => Ok(rustler::types::atom::ok()),
            None => Err(rustler::Error::Term(Box::new("Connection not found"))),
        }
    } else if opt == trx_id() {
        let removed = crate::utils::safe_lock(&TXN_REGISTRY, "close trx")?.remove(id);
        match removed {
            Some(_) => Ok(rustler::types::atom::ok()),
            None => Err(rustler::Error::Term(Box::new("Transaction not found"))),
        }
    } else if opt == stmt_id() {
        let removed = crate::utils::safe_lock(&STMT_REGISTRY, "close stmt")?.remove(id);
        match removed {
            Some(_) => Ok(rustler::types::atom::ok()),
            None => Err(rustler::Error::Term(Box::new("Statement not found"))),
        }
    } else if opt == cursor_id() {
        let removed = crate::utils::safe_lock(&CURSOR_REGISTRY, "close cursor")?.remove(id);
        match removed {
            Some(_) => Ok(rustler::types::atom::ok()),
            None => Err(rustler::Error::Term(Box::new("Cursor not found"))),
        }
    } else {
        Err(rustler::Error::Term(Box::new("opt is incorrect")))
    }
}

/// Set the busy timeout for a database connection.
///
/// Controls how long SQLite waits for locks before returning `SQLITE_BUSY`.
/// Default SQLite behavior is to return immediately; setting a timeout allows
/// for better concurrency handling in high-contention scenarios.
///
/// # Arguments
/// - `conn_id`: Database connection ID
/// - `timeout_ms`: Timeout in milliseconds
///
/// Returns `:ok` on success, error on failure.
#[rustler::nif(schedule = "DirtyIo")]
pub fn set_busy_timeout(conn_id: &str, timeout_ms: u64) -> NifResult<Atom> {
    let conn_map = crate::utils::safe_lock(&CONNECTION_REGISTRY, "set_busy_timeout conn_map")?;

    if let Some(client) = conn_map.get(conn_id) {
        let client = client.clone();
        drop(conn_map); // Release lock before blocking operation

        let result = TOKIO_RUNTIME.block_on(async {
            let client_guard = safe_lock_arc(&client, "set_busy_timeout client")?;
            let conn_guard: std::sync::MutexGuard<libsql::Connection> =
                safe_lock_arc(&client_guard.client, "set_busy_timeout conn")?;

            conn_guard
                .busy_timeout(Duration::from_millis(timeout_ms))
                .map_err(|e| rustler::Error::Term(Box::new(format!("busy_timeout failed: {}", e))))
        });

        match result {
            Ok(()) => Ok(rustler::types::atom::ok()),
            Err(e) => Err(e),
        }
    } else {
        Err(rustler::Error::Term(Box::new("Invalid connection ID")))
    }
}

/// Reset the connection state to a clean state.
///
/// This clears any prepared statements and resets the connection to a clean state.
/// Useful for connection pooling to ensure connections are clean when returned to the pool.
///
/// # Arguments
/// - `conn_id`: Database connection ID
///
/// Returns `:ok` on success, error on failure.
#[rustler::nif(schedule = "DirtyIo")]
pub fn reset_connection(conn_id: &str) -> NifResult<Atom> {
    let conn_map = crate::utils::safe_lock(&CONNECTION_REGISTRY, "reset_connection conn_map")?;

    if let Some(client) = conn_map.get(conn_id) {
        let client = client.clone();
        drop(conn_map); // Release lock before blocking operation

        TOKIO_RUNTIME.block_on(async {
            let client_guard = safe_lock_arc(&client, "reset_connection client")?;
            let conn_guard: std::sync::MutexGuard<libsql::Connection> =
                safe_lock_arc(&client_guard.client, "reset_connection conn")?;

            conn_guard.reset().await;
            Ok::<(), rustler::Error>(())
        })?;

        Ok(rustler::types::atom::ok())
    } else {
        Err(rustler::Error::Term(Box::new("Invalid connection ID")))
    }
}

/// Interrupt any ongoing operation on a database connection.
///
/// Causes the current operation to return at the earliest opportunity.
/// Useful for cancelling long-running queries that might otherwise block.
///
/// # Arguments
/// - `conn_id`: Database connection ID
///
/// Returns `:ok` on success, error on failure.
#[rustler::nif(schedule = "DirtyIo")]
pub fn interrupt_connection(conn_id: &str) -> NifResult<Atom> {
    let conn_map = crate::utils::safe_lock(&CONNECTION_REGISTRY, "interrupt_connection conn_map")?;

    if let Some(client) = conn_map.get(conn_id) {
        let client = client.clone();
        drop(conn_map); // Release lock before operation

        let client_guard = safe_lock_arc(&client, "interrupt_connection client")?;
        let conn_guard: std::sync::MutexGuard<libsql::Connection> =
            safe_lock_arc(&client_guard.client, "interrupt_connection conn")?;

        conn_guard
            .interrupt()
            .map_err(|e| rustler::Error::Term(Box::new(format!("interrupt failed: {}", e))))?;

        Ok(rustler::types::atom::ok())
    } else {
        Err(rustler::Error::Term(Box::new("Invalid connection ID")))
    }
}
