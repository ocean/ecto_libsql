/// Connection lifecycle management for LibSQL/Turso databases
///
/// This module handles database connection establishment, health checking,
/// and connection state management including cleanup and timeouts.
use crate::constants::*;
use crate::decode;
use crate::models::{LibSQLConn, Mode};
use crate::utils::safe_lock_arc;
use bytes::Bytes;
use libsql::{Builder, Cipher, EncryptionConfig, EncryptionContext, EncryptionKey};
use rustler::{Atom, NifResult, Term};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use uuid::Uuid;

/// Establish a database connection to a local, remote, or remote replica database.
///
/// Supports three connection modes:
/// - **local**: Direct connection to a local `SQLite` file
/// - **remote**: Direct connection to a remote `LibSQL`/Turso server
/// - **remote_replica**: Local replica with automatic sync to remote
///
/// Connection parameters are passed as Elixir keyword list:
/// - `database` - Path to local database file (required for `local`/`remote_replica` modes)
/// - `uri` - Remote database URI (required for `remote`/`remote_replica` modes)
/// - `auth_token` - Authentication token (required for `remote`/`remote_replica` modes)
/// - `encryption_key` - Optional local encryption key for local database encryption at rest (`local`/`remote_replica` modes)
/// - `remote_encryption_key` - Optional remote encryption key for Turso encrypted databases (`remote`/`remote_replica` modes)
///
/// **Encryption Support**:
/// - **Local encryption**: Uses AES-256-CBC for local database files (via `encryption_key`)
/// - **Remote encryption**: Sends encryption key with each request to Turso (via `remote_encryption_key`)
/// - **Remote replica**: Supports both local and remote encryption simultaneously
///
/// Returns the connection ID as a string on success, or an error on failure.
///
/// **Timeouts**: Connection establishment has a 30-second timeout to prevent hanging.
#[rustler::nif(schedule = "DirtyIo")]
pub fn connect(opts: Term, mode: Term) -> NifResult<String> {
    let list: Vec<Term> = opts
        .decode()
        .map_err(|e| rustler::Error::Term(Box::new(format!("decode failed: {e:?}"))))?;

    let mut map = HashMap::with_capacity(list.len());

    for pair in list {
        let (key, value): (rustler::Atom, Term) = pair.decode().map_err(|e| {
            rustler::Error::Term(Box::new(format!("expected keyword tuple: {e:?}")))
        })?;
        map.insert(format!("{key:?}"), value);
    }

    let url = map.get("uri").and_then(|t| t.decode::<String>().ok());
    let token = map
        .get("auth_token")
        .and_then(|t| t.decode::<String>().ok());
    let dbname = map.get("database").and_then(|t| t.decode::<String>().ok());
    let encryption_key = map
        .get("encryption_key")
        .and_then(|t| t.decode::<String>().ok());
    let remote_encryption_key = map
        .get("remote_encryption_key")
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

                    // Local encryption for the replica file (at-rest encryption)
                    if let Some(key) = encryption_key {
                        let config = EncryptionConfig {
                            cipher: Cipher::Aes256Cbc,
                            encryption_key: Bytes::from(key),
                        };
                        builder = builder.encryption_config(config);
                    }

                    // Remote encryption for Turso encrypted databases (sent with each request)
                    if let Some(key) = remote_encryption_key {
                        let encryption_context = EncryptionContext {
                            key: EncryptionKey::Base64Encoded(key),
                        };
                        builder = builder.remote_encryption(encryption_context);
                    }

                    builder.build().await
                }
                Mode::Remote => {
                    let url = url.ok_or_else(|| rustler::Error::BadArg)?;
                    let token = token.ok_or_else(|| rustler::Error::BadArg)?;

                    let mut builder = Builder::new_remote(url, token);

                    // Remote encryption for Turso encrypted databases
                    if let Some(key) = remote_encryption_key {
                        let encryption_context = EncryptionContext {
                            key: EncryptionKey::Base64Encoded(key),
                        };
                        builder = builder.remote_encryption(encryption_context);
                    }

                    builder.build().await
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
            .map_err(|e| rustler::Error::Term(Box::new(format!("Failed to build DB: {e}"))))?;

            let conn = db
                .connect()
                .map_err(|e| rustler::Error::Term(Box::new(format!("Failed to connect: {e}"))))?;

            // Ping remote connections to verify they're accessible
            if mode_enum != Mode::Local {
                conn.query("SELECT 1", ())
                    .await
                    .map_err(|e| rustler::Error::Term(Box::new(format!("Failed ping: {e}"))))?;
            }

            let libsql_conn = Arc::new(Mutex::new(LibSQLConn {
                db,
                client: Arc::new(Mutex::new(conn)),
            }));

            let conn_id = Uuid::new_v4().to_string();
            crate::utils::safe_lock(&CONNECTION_REGISTRY, "connect conn_registry")
                .map_err(|e| {
                    rustler::Error::Term(Box::new(format!("Failed to register connection: {e:?}")))
                })?
                .insert(conn_id.clone(), libsql_conn);

            Ok(conn_id)
        })
        .await
        .map_err(|_| {
            rustler::Error::Term(Box::new(format!(
                "Connection timeout after {DEFAULT_SYNC_TIMEOUT_SECS} seconds"
            )))
        })?
    })
}

/// Check if a database connection is alive and responsive.
///
/// Performs a simple `SELECT 1` query to verify the connection is working.
/// Returns `true` if the connection is healthy, error otherwise.
#[rustler::nif(schedule = "DirtyIo")]
pub fn ping(conn_id: &str) -> NifResult<bool> {
    let conn_map = crate::utils::safe_lock(&CONNECTION_REGISTRY, "ping conn_map")?;

    let maybe_conn = conn_map.get(conn_id);
    if let Some(conn) = maybe_conn {
        let client = conn.clone();
        drop(conn_map); // Release lock before async operation

        // SAFETY: We're inside TOKIO_RUNTIME.block_on(), so this is synchronous execution.
        // The std::sync::Mutex guards are safe to hold across await points here because
        // we're not in a true async context - block_on runs the future to completion.
        #[allow(clippy::await_holding_lock)]
        let result = TOKIO_RUNTIME.block_on(async {
            let client_guard =
                safe_lock_arc(&client, "ping client").map_err(|e| format!("{e:?}"))?;
            let conn_guard: std::sync::MutexGuard<libsql::Connection> =
                safe_lock_arc(&client_guard.client, "ping conn").map_err(|e| format!("{e:?}"))?;

            conn_guard
                .query("SELECT 1", ())
                .await
                .map_err(|e| format!("{e:?}"))
        });
        match result {
            Ok(_) => Ok(true),
            Err(e) => Err(rustler::Error::Term(Box::new(format!("Ping error: {e:?}")))),
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
/// Controls how long `SQLite` waits for locks before returning `SQLITE_BUSY`.
/// Default `SQLite` behaviour is to return immediately; setting a timeout allows
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
                .map_err(|e| rustler::Error::Term(Box::new(format!("busy_timeout failed: {e}"))))
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

        // SAFETY: We're inside TOKIO_RUNTIME.block_on(), so this is synchronous execution.
        // The std::sync::Mutex guards are safe to hold across await points here because
        // we're not in a true async context - block_on runs the future to completion.
        #[allow(clippy::await_holding_lock)]
        {
            TOKIO_RUNTIME.block_on(async {
                let client_guard = safe_lock_arc(&client, "reset_connection client")?;
                let conn_guard: std::sync::MutexGuard<libsql::Connection> =
                    safe_lock_arc(&client_guard.client, "reset_connection conn")?;

                conn_guard.reset().await;
                Ok::<(), rustler::Error>(())
            })?;
        }

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
            .map_err(|e| rustler::Error::Term(Box::new(format!("interrupt failed: {e}"))))?;

        Ok(rustler::types::atom::ok())
    } else {
        Err(rustler::Error::Term(Box::new("Invalid connection ID")))
    }
}

/// Enable or disable loading of SQLite extensions.
///
/// By default, extension loading is disabled for security reasons.
/// You must explicitly enable it before calling `load_extension`.
///
/// # Arguments
/// - `conn_id`: Database connection ID
/// - `enabled`: Whether to enable (true) or disable (false) extension loading
///
/// # Returns
/// - `:ok` - Extension loading enabled/disabled successfully
/// - `{:error, reason}` - Operation failed
///
/// # Security Warning
/// Only enable extension loading if you trust the extensions being loaded.
/// Malicious extensions can compromise database security.
#[rustler::nif(schedule = "DirtyIo")]
pub fn enable_load_extension(conn_id: &str, enabled: bool) -> NifResult<Atom> {
    let conn_map = crate::utils::safe_lock(&CONNECTION_REGISTRY, "enable_load_extension conn_map")?;

    if let Some(client) = conn_map.get(conn_id) {
        let client = client.clone();
        drop(conn_map); // Release lock before operation

        let client_guard = safe_lock_arc(&client, "enable_load_extension client")?;
        let conn_guard: std::sync::MutexGuard<libsql::Connection> =
            safe_lock_arc(&client_guard.client, "enable_load_extension conn")?;

        if enabled {
            conn_guard.load_extension_enable().map_err(|e| {
                rustler::Error::Term(Box::new(format!("Failed to enable extension loading: {e}")))
            })?;
        } else {
            conn_guard.load_extension_disable().map_err(|e| {
                rustler::Error::Term(Box::new(format!(
                    "Failed to disable extension loading: {e}"
                )))
            })?;
        }

        Ok(rustler::types::atom::ok())
    } else {
        Err(rustler::Error::Term(Box::new("Invalid connection ID")))
    }
}

/// Load a SQLite extension from a dynamic library file.
///
/// Extensions must be enabled first via `enable_load_extension(conn_id, true)`.
///
/// # Arguments
/// - `conn_id`: Database connection ID
/// - `path`: Path to the extension dynamic library (.so, .dylib, or .dll)
/// - `entry_point`: Optional entry point function name (defaults to extension-specific default)
///
/// # Returns
/// - `:ok` - Extension loaded successfully
/// - `{:error, reason}` - Extension loading failed
///
/// # Security Warning
/// Only load extensions from trusted sources. Extensions run with full database
/// access and can execute arbitrary code.
///
/// # Common Extensions
/// - FTS5 (full-text search) - usually built-in, but can be loaded separately
/// - JSON1 (JSON functions) - usually built-in
/// - R-Tree (spatial indexing)
/// - Custom user-defined functions
#[rustler::nif(schedule = "DirtyIo")]
pub fn load_extension(conn_id: &str, path: &str, entry_point: Option<&str>) -> NifResult<Atom> {
    let conn_map = crate::utils::safe_lock(&CONNECTION_REGISTRY, "load_extension conn_map")?;

    if let Some(client) = conn_map.get(conn_id) {
        let client = client.clone();
        drop(conn_map); // Release lock before operation

        let path_buf = std::path::PathBuf::from(path);

        let client_guard = safe_lock_arc(&client, "load_extension client")?;
        let conn_guard: std::sync::MutexGuard<libsql::Connection> =
            safe_lock_arc(&client_guard.client, "load_extension conn")?;

        conn_guard
            .load_extension(&path_buf, entry_point)
            .map_err(|e| {
                rustler::Error::Term(Box::new(format!("Failed to load extension: {e}")))
            })?;

        Ok(rustler::types::atom::ok())
    } else {
        Err(rustler::Error::Term(Box::new("Invalid connection ID")))
    }
}
