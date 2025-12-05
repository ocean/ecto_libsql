use bytes::Bytes;
use lazy_static::lazy_static;
use libsql::{
    Builder, Cipher, EncryptionConfig, Rows, Statement, Transaction, TransactionBehavior, Value,
};
use once_cell::sync::Lazy;
use rustler::atoms;
use rustler::types::atom::nil;
use rustler::{resource_impl, Atom, Binary, Encoder, Env, NifResult, OwnedBinary, Resource, Term};
use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;
use tokio::runtime::Runtime;
use uuid::Uuid;

// Helper function to safely lock a mutex with proper error handling
fn safe_lock<'a, T>(
    mutex: &'a Mutex<T>,
    context: &str,
) -> Result<MutexGuard<'a, T>, rustler::Error> {
    mutex.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!("Mutex poisoned in {}: {}", context, e)))
    })
}

// Helper function to safely lock nested Arc<Mutex<T>>
fn safe_lock_arc<'a, T>(
    arc_mutex: &'a Arc<Mutex<T>>,
    context: &str,
) -> Result<MutexGuard<'a, T>, rustler::Error> {
    arc_mutex.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "Arc mutex poisoned in {}: {}",
            context, e
        )))
    })
}

static TOKIO_RUNTIME: Lazy<Runtime> =
    Lazy::new(|| Runtime::new().expect("Failed to create Tokio runtime"));

// Default timeout for sync operations (in seconds).
const DEFAULT_SYNC_TIMEOUT_SECS: u64 = 30;

// Helper function to perform sync with timeout.
async fn sync_with_timeout(
    client: &Arc<Mutex<LibSQLConn>>,
    timeout_secs: u64,
) -> Result<(), String> {
    let timeout = Duration::from_secs(timeout_secs);

    tokio::time::timeout(timeout, async {
        let client_guard =
            safe_lock_arc(client, "sync_with_timeout client").map_err(|e| format!("{:?}", e))?;
        client_guard
            .db
            .sync()
            .await
            .map_err(|e| format!("Sync error: {}", e))?;
        Ok::<_, String>(())
    })
    .await
    .map_err(|_| format!("Sync timeout after {} seconds", timeout_secs))?
}

#[resource_impl]
impl Resource for LibSQLConn {}

#[derive(Debug)]
pub struct LibSQLConn {
    pub db: libsql::Database,
    pub client: Arc<Mutex<libsql::Connection>>,
}

#[derive(Debug)]
pub struct CursorData {
    pub conn_id: String,
    pub columns: Vec<String>,
    pub rows: Vec<Vec<Value>>,
    pub position: usize,
}

/// Transaction with ownership tracking
pub struct TransactionEntry {
    pub conn_id: String,
    pub transaction: Transaction,
}

lazy_static! {
    static ref TXN_REGISTRY: Mutex<HashMap<String, TransactionEntry>> = Mutex::new(HashMap::new());
    static ref STMT_REGISTRY: Mutex<HashMap<String, (String, Arc<Mutex<Statement>>)>> = Mutex::new(HashMap::new()); // (conn_id, cached_statement)
    static ref CURSOR_REGISTRY: Mutex<HashMap<String, CursorData>> = Mutex::new(HashMap::new());
    pub static ref CONNECTION_REGISTRY: Mutex<HashMap<String, Arc<Mutex<LibSQLConn>>>> =
        Mutex::new(HashMap::new());
}

atoms! {
    local,
    remote_primary,
    remote_replica,
    ok,
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
    blob
}

enum Mode {
    RemoteReplica,
    Remote,
    Local,
}
fn decode_mode(atom: Atom) -> Option<Mode> {
    if atom == remote_replica() {
        Some(Mode::RemoteReplica)
    } else if atom == remote_primary() {
        Some(Mode::Remote)
    } else if atom == local() {
        Some(Mode::Local)
    } else {
        None
    }
}

fn decode_transaction_behavior(atom: Atom) -> Option<TransactionBehavior> {
    if atom == deferred() {
        Some(TransactionBehavior::Deferred)
    } else if atom == immediate() {
        Some(TransactionBehavior::Immediate)
    } else if atom == exclusive() {
        Some(TransactionBehavior::Exclusive)
    } else if atom == read_only() {
        Some(TransactionBehavior::ReadOnly)
    } else {
        None
    }
}

/// Helper function to verify transaction ownership.
///
/// Returns an error if the transaction does not belong to the specified connection.
fn verify_transaction_ownership(
    entry: &TransactionEntry,
    conn_id: &str,
) -> Result<(), rustler::Error> {
    if entry.conn_id != conn_id {
        return Err(rustler::Error::Term(Box::new(
            "Transaction does not belong to this connection",
        )));
    }
    Ok(())
}

/// Helper function to verify statement ownership.
///
/// Returns an error if the statement does not belong to the specified connection.
fn verify_statement_ownership(stmt_conn_id: &str, conn_id: &str) -> Result<(), rustler::Error> {
    if stmt_conn_id != conn_id {
        return Err(rustler::Error::Term(Box::new(
            "Statement does not belong to connection",
        )));
    }
    Ok(())
}

/// Helper function to verify cursor ownership.
///
/// Returns an error if the cursor does not belong to the specified connection.
fn verify_cursor_ownership(cursor: &CursorData, conn_id: &str) -> Result<(), rustler::Error> {
    if cursor.conn_id != conn_id {
        return Err(rustler::Error::Term(Box::new(
            "Cursor does not belong to connection",
        )));
    }
    Ok(())
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn begin_transaction(conn_id: &str) -> NifResult<String> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "begin_transaction conn_map")?;
    if let Some(conn) = conn_map.get(conn_id) {
        let conn_guard = safe_lock_arc(conn, "begin_transaction conn")?;
        let client_guard = safe_lock_arc(&conn_guard.client, "begin_transaction client")?;

        let trx = TOKIO_RUNTIME
            .block_on(async { client_guard.transaction().await })
            .map_err(|e| rustler::Error::Term(Box::new(format!("Begin failed: {}", e))))?;

        let trx_id = Uuid::new_v4().to_string();
        let entry = TransactionEntry {
            conn_id: conn_id.to_string(),
            transaction: trx,
        };
        safe_lock(&TXN_REGISTRY, "begin_transaction txn_registry")?.insert(trx_id.clone(), entry);

        Ok(trx_id)
    } else {
        println!(
            "Connection ID not found begin transaction new : {}",
            conn_id
        );
        Err(rustler::Error::Term(Box::new("Invalid connection ID")))
    }
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn begin_transaction_with_behavior(conn_id: &str, behavior: Atom) -> NifResult<String> {
    let conn_map = safe_lock(
        &CONNECTION_REGISTRY,
        "begin_transaction_with_behavior conn_map",
    )?;
    if let Some(conn) = conn_map.get(conn_id) {
        let trx_behavior =
            decode_transaction_behavior(behavior).unwrap_or(TransactionBehavior::Deferred);

        let conn_guard = safe_lock_arc(conn, "begin_transaction_with_behavior conn")?;
        let client_guard =
            safe_lock_arc(&conn_guard.client, "begin_transaction_with_behavior client")?;

        let trx = TOKIO_RUNTIME
            .block_on(async { client_guard.transaction_with_behavior(trx_behavior).await })
            .map_err(|e| rustler::Error::Term(Box::new(format!("Begin failed: {}", e))))?;

        let trx_id = Uuid::new_v4().to_string();
        let entry = TransactionEntry {
            conn_id: conn_id.to_string(),
            transaction: trx,
        };
        safe_lock(
            &TXN_REGISTRY,
            "begin_transaction_with_behavior txn_registry",
        )?
        .insert(trx_id.clone(), entry);

        Ok(trx_id)
    } else {
        println!(
            "Connection ID not found begin transaction new : {}",
            conn_id
        );
        Err(rustler::Error::Term(Box::new("Invalid connection ID")))
    }
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn execute_with_transaction<'a>(
    trx_id: &str,
    conn_id: &str,
    query: &str,
    args: Vec<Term<'a>>,
) -> NifResult<u64> {
    let mut txn_registry = safe_lock(&TXN_REGISTRY, "execute_with_transaction")?;

    let entry = txn_registry
        .get_mut(trx_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Transaction not found")))?;

    // Verify transaction belongs to this connection
    verify_transaction_ownership(entry, conn_id)?;

    let decoded_args: Vec<Value> = args
        .into_iter()
        .map(|t| decode_term_to_value(t))
        .collect::<Result<_, _>>()
        .map_err(|e| rustler::Error::Term(Box::new(e)))?;

    let result = TOKIO_RUNTIME
        .block_on(async { entry.transaction.execute(&query, decoded_args).await })
        .map_err(|e| rustler::Error::Term(Box::new(format!("Execute failed: {}", e))))?;

    Ok(result)
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn query_with_trx_args<'a>(
    env: Env<'a>,
    trx_id: &str,
    conn_id: &str,
    query: &str,
    args: Vec<Term<'a>>,
) -> NifResult<Term<'a>> {
    let mut txn_registry = safe_lock(&TXN_REGISTRY, "query_with_trx_args")?;

    let entry = txn_registry
        .get_mut(trx_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Transaction not found")))?;

    // Verify transaction belongs to this connection
    verify_transaction_ownership(entry, conn_id)?;

    let decoded_args: Vec<Value> = args
        .into_iter()
        .map(|t| decode_term_to_value(t))
        .collect::<Result<_, _>>()
        .map_err(|e| rustler::Error::Term(Box::new(e)))?;

    TOKIO_RUNTIME.block_on(async {
        let res_rows = entry
            .transaction
            .query(&query, decoded_args)
            .await
            .map_err(|e| rustler::Error::Term(Box::new(format!("Query failed: {}", e))))?;

        collect_rows(env, res_rows).await
    })
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn handle_status_transaction(trx_id: &str) -> NifResult<rustler::Atom> {
    let trx_registy = safe_lock(&TXN_REGISTRY, "handle_status_transaction")?;
    let trx = trx_registy.get(trx_id);

    match trx {
        Some(_) => return Ok(rustler::types::atom::ok()),

        None => return Err(rustler::Error::Term(Box::new("Transaction not found"))),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn do_sync(conn_id: &str, mode: Atom) -> NifResult<(rustler::Atom, String)> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "do_sync")?;
    let client = conn_map
        .get(conn_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Connection not found")))?;

    let client_clone = client.clone();
    let result = TOKIO_RUNTIME.block_on(async {
        if matches!(decode_mode(mode), Some(Mode::RemoteReplica)) {
            sync_with_timeout(&client_clone, DEFAULT_SYNC_TIMEOUT_SECS).await?;
        }

        Ok::<_, String>(())
    });

    match result {
        Ok(()) => Ok((rustler::types::atom::ok(), format!("success sync"))),
        Err(e) => Err(rustler::Error::Term(Box::new(e))),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn commit_or_rollback_transaction(
    trx_id: &str,
    conn_id: &str,
    _mode: Atom,
    _syncx: Atom,
    param: &str,
) -> NifResult<(rustler::Atom, String)> {
    // First, lock the registry and verify ownership before removing
    let entry = {
        let mut registry = safe_lock(&TXN_REGISTRY, "commit_or_rollback txn_registry")?;

        // Peek at the entry to verify it exists and check ownership
        let existing = registry
            .get(trx_id)
            .ok_or_else(|| rustler::Error::Term(Box::new("Transaction not found")))?;

        // Verify that the transaction belongs to the requesting connection
        if existing.conn_id != conn_id {
            return Err(rustler::Error::Term(Box::new(
                "Transaction does not belong to this connection",
            )));
        }

        // Only remove after ownership is verified
        registry
            .remove(trx_id)
            .expect("Transaction was just verified to exist")
    };

    let result = TOKIO_RUNTIME.block_on(async {
        if param == "commit" {
            entry
                .transaction
                .commit()
                .await
                .map_err(|e| format!("Commit error: {}", e))?;
        } else {
            entry
                .transaction
                .rollback()
                .await
                .map_err(|e| format!("Rollback error: {}", e))?;
        }

        // NOTE: LibSQL automatically syncs transaction commits to remote for embedded replicas.
        // No manual sync needed here.

        Ok::<_, String>(())
    });

    match result {
        Ok(()) => Ok((rustler::types::atom::ok(), format!("{}  success", param))),
        Err(e) => Err(rustler::Error::Term(Box::new(format!(
            "TOKIO_RUNTIME ERR {}",
            e.to_string()
        )))),
    }
}
#[rustler::nif]
pub fn close(id: &str, opt: Atom) -> NifResult<rustler::Atom> {
    if opt == conn_id() {
        let removed = safe_lock(&CONNECTION_REGISTRY, "close conn")?.remove(id);
        match removed {
            Some(_) => Ok(rustler::types::atom::ok()),
            None => Err(rustler::Error::Term(Box::new("Connection not found"))),
        }
    } else if opt == trx_id() {
        let removed = safe_lock(&TXN_REGISTRY, "close trx")?.remove(id);
        match removed {
            Some(_) => Ok(rustler::types::atom::ok()),
            None => Err(rustler::Error::Term(Box::new("Transaction not found"))),
        }
    } else if opt == stmt_id() {
        let removed = safe_lock(&STMT_REGISTRY, "close stmt")?.remove(id);
        match removed {
            Some(_) => Ok(rustler::types::atom::ok()),
            None => Err(rustler::Error::Term(Box::new("Statement not found"))),
        }
    } else if opt == cursor_id() {
        let removed = safe_lock(&CURSOR_REGISTRY, "close cursor")?.remove(id);
        match removed {
            Some(_) => Ok(rustler::types::atom::ok()),
            None => Err(rustler::Error::Term(Box::new("Cursor not found"))),
        }
    } else {
        Err(rustler::Error::Term(Box::new("opt is incorrect")))
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn connect(opts: Term, mode: Term) -> NifResult<String> {
    let list: Vec<Term> = opts
        .decode()
        .map_err(|e| rustler::Error::Term(Box::new(format!("decode failed: {:?}", e))))?;

    let mut map = HashMap::new();

    for pair in list {
        let (key, value): (Atom, Term) = pair.decode().map_err(|e| {
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

    let rt = tokio::runtime::Runtime::new()
        .map_err(|e| rustler::Error::Term(Box::new(format!("Tokio runtime err {}", e))))?;

    // Wrap the entire connection process with a timeout.
    rt.block_on(async {
        let timeout = Duration::from_secs(DEFAULT_SYNC_TIMEOUT_SECS);

        tokio::time::timeout(timeout, async {
            let db = match mode.atom_to_string() {
                Ok(mode_str) => {
                    if mode_str == "remote_replica" {
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
                    } else if mode_str == "remote" {
                        let url = url.ok_or_else(|| rustler::Error::BadArg)?;
                        let token = token.ok_or_else(|| rustler::Error::BadArg)?;

                        Builder::new_remote(url, token).build().await
                    } else if mode_str == "local" {
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
                    } else {
                        // else value will return string error
                        return Err(rustler::Error::Term(Box::new(format!("Unknown mode",))));
                    }
                }

                Err(other) => {
                    return Err(rustler::Error::Term(Box::new(format!(
                        "Unknown mode: {:?}",
                        other
                    ))))
                }
            }
            .map_err(|e| rustler::Error::Term(Box::new(format!("Failed to build DB: {}", e))))?;

            let conn = db
                .connect()
                .map_err(|e| rustler::Error::Term(Box::new(format!("Failed to connect: {}", e))))?;

            let mode_str = mode.atom_to_string().map_err(|e| {
                rustler::Error::Term(Box::new(format!("Invalid mode atom: {:?}", e)))
            })?;

            if mode_str != "local" {
                conn.query("SELECT 1", ())
                    .await
                    .map_err(|e| rustler::Error::Term(Box::new(format!("Failed ping: {}", e))))?;
            }

            let libsql_conn = Arc::new(Mutex::new(LibSQLConn {
                db,
                client: Arc::new(Mutex::new(conn)),
            }));

            let conn_id = Uuid::new_v4().to_string();
            safe_lock(&CONNECTION_REGISTRY, "connect conn_registry")
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

#[rustler::nif(schedule = "DirtyIo")]
fn query_args<'a>(
    env: Env<'a>,
    conn_id: &str,
    _mode: Atom,
    _syncx: Atom,
    query: &str,
    args: Vec<Term<'a>>,
) -> NifResult<Term<'a>> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "query_args conn_map")?;

    let _is_sync = !matches!(detect_query_type(query), QueryType::Select);

    if let Some(client) = conn_map.get(conn_id) {
        let client = client.clone();

        let params: Result<Vec<Value>, _> =
            args.into_iter().map(|t| decode_term_to_value(t)).collect();

        let params = params.map_err(|e| rustler::Error::Term(Box::new(e)))?;

        TOKIO_RUNTIME.block_on(async {
            let client_guard = safe_lock_arc(&client, "query_args client")?;
            let conn_guard = safe_lock_arc(&client_guard.client, "query_args conn")?;

            let res = conn_guard.query(query, params).await;

            match res {
                Ok(res_rows) => {
                    let result = collect_rows(env, res_rows).await?;

                    // NOTE: LibSQL automatically syncs writes to remote for embedded replicas.
                    // According to Turso docs, "writes are sent to the remote primary database by default,
                    // then the local database updates automatically once the remote write succeeds."
                    // We do NOT need to manually call sync() after writes - that would be redundant
                    // and cause performance issues. Manual sync via do_sync() is still available for
                    // explicit user control.

                    Ok(result)
                }

                Err(e) => Err(rustler::Error::Term(Box::new(e.to_string()))),
            }
        })
    } else {
        println!("query args Connection ID not found: {}", conn_id);
        Err(rustler::Error::Term(Box::new("Invalid connection ID")))
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn ping(conn_id: String) -> NifResult<bool> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "ping conn_map")?;

    let maybe_conn = conn_map.get(&conn_id);
    if let Some(conn) = maybe_conn {
        let client = conn.clone();
        drop(conn_map); // Release lock before async operation

        let result = TOKIO_RUNTIME.block_on(async {
            let client_guard =
                safe_lock_arc(&client, "ping client").map_err(|e| format!("{:?}", e))?;
            let conn_guard =
                safe_lock_arc(&client_guard.client, "ping conn").map_err(|e| format!("{:?}", e))?;

            conn_guard
                .query("SELECT 1", ())
                .await
                .map_err(|e| format!("{:?}", e))
        });
        match result {
            Ok(_) => Ok(true),
            Err(e) => {
                println!("Ping failed: {:?}", e);
                Err(rustler::Error::Term(Box::new(format!(
                    "Ping error: {:?}",
                    e
                ))))
            }
        }
    } else {
        println!("Connection ID not found ping replica: {}", conn_id);
        Err(rustler::Error::Term(Box::new("Invalid connection ID")))
    }
}

pub fn decode_term_to_value(term: Term) -> Result<Value, String> {
    if let Ok(v) = term.decode::<i64>() {
        Ok(Value::Integer(v))
    } else if let Ok(v) = term.decode::<f64>() {
        Ok(Value::Real(v))
    } else if let Ok(v) = term.decode::<bool>() {
        Ok(Value::Integer(if v { 1 } else { 0 }))
    } else if let Ok(v) = term.decode::<String>() {
        Ok(Value::Text(v))
    } else if let Ok((atom, data)) = term.decode::<(Atom, Vec<u8>)>() {
        // Handle {:blob, data} tuple from Ecto binary dumper
        if atom == blob() {
            Ok(Value::Blob(data))
        } else {
            Err(format!("Unsupported atom tuple: {:?}", atom))
        }
    } else if let Ok(v) = term.decode::<Binary>() {
        // Handle Elixir binaries (including BLOBs)
        Ok(Value::Blob(v.as_slice().to_vec()))
    } else if let Ok(v) = term.decode::<Vec<u8>>() {
        Ok(Value::Blob(v))
    } else {
        Err(format!("Unsupported argument type: {:?}", term))
    }
}

async fn collect_rows<'a>(env: Env<'a>, mut rows: Rows) -> Result<Term<'a>, rustler::Error> {
    let mut column_names: Vec<String> = Vec::new();
    let mut collected_rows: Vec<Vec<Term<'a>>> = Vec::new();

    while let Some(row_result) = rows
        .next()
        .await
        .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?
    {
        if column_names.is_empty() {
            for i in 0..row_result.column_count() {
                if let Some(name) = row_result.column_name(i) {
                    column_names.push(name.to_string());
                } else {
                    column_names.push(format!("col{}", i));
                }
            }
        }

        let mut row_terms = Vec::new();
        for i in 0..column_names.len() {
            let term = match row_result.get(i as i32) {
                Ok(Value::Text(val)) => val.encode(env),
                Ok(Value::Integer(val)) => val.encode(env),
                Ok(Value::Real(val)) => val.encode(env),
                Ok(Value::Blob(val)) => match OwnedBinary::new(val.len()) {
                    Some(mut owned) => {
                        owned.as_mut_slice().copy_from_slice(&val);
                        Binary::from_owned(owned, env).encode(env)
                    }
                    None => nil().encode(env),
                },
                Ok(Value::Null) => nil().encode(env),
                Err(_) => nil().encode(env),
            };
            row_terms.push(term);
        }
        collected_rows.push(row_terms);
    }

    //Ok((column_names, collected_rows))

    let encoded_columns: Vec<Term> = column_names.iter().map(|c| c.encode(env)).collect();
    let encoded_rows: Vec<Term> = collected_rows.iter().map(|r| r.encode(env)).collect();

    let mut result_map: HashMap<String, Term<'a>> = HashMap::new();
    result_map.insert("columns".to_string(), encoded_columns.encode(env));
    result_map.insert("rows".to_string(), encoded_rows.encode(env));
    result_map.insert(
        "num_rows".to_string(),
        (collected_rows.len() as u64).encode(env),
    );

    Ok(result_map.encode(env))
}

#[derive(Debug, PartialEq, Eq)]
pub enum QueryType {
    Select,
    Insert,
    Update,
    Delete,
    Create,
    Drop,
    Alter,
    Begin,
    Commit,
    Rollback,
    Other,
}

pub fn detect_query_type(query: &str) -> QueryType {
    let trimmed = query.trim_start();
    let keyword = trimmed
        .split_whitespace()
        .next()
        .unwrap_or("")
        .to_uppercase();

    match keyword.as_str() {
        "SELECT" => QueryType::Select,
        "INSERT" => QueryType::Insert,
        "UPDATE" => QueryType::Update,
        "DELETE" => QueryType::Delete,
        "CREATE" => QueryType::Create,
        "DROP" => QueryType::Drop,
        "ALTER" => QueryType::Alter,
        "BEGIN" => QueryType::Begin,
        "COMMIT" => QueryType::Commit,
        "ROLLBACK" => QueryType::Rollback,
        _ => QueryType::Other,
    }
}
// Batch execution support - executes statements sequentially without transaction
#[rustler::nif(schedule = "DirtyIo")]
fn execute_batch<'a>(
    env: Env<'a>,
    conn_id: &str,
    _mode: Atom,
    _syncx: Atom,
    statements: Vec<Term<'a>>,
) -> Result<NifResult<Term<'a>>, rustler::Error> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "execute_batch conn_map")?;

    if let Some(client) = conn_map.get(conn_id) {
        let client = client.clone();

        // Decode each statement with its arguments
        let mut batch_stmts: Vec<(String, Vec<Value>)> = Vec::new();
        for stmt_term in statements {
            let (query, args): (String, Vec<Term>) = stmt_term.decode().map_err(|e| {
                rustler::Error::Term(Box::new(format!("Failed to decode statement: {:?}", e)))
            })?;

            let decoded_args: Vec<Value> = args
                .into_iter()
                .map(|t| decode_term_to_value(t))
                .collect::<Result<_, _>>()
                .map_err(|e| rustler::Error::Term(Box::new(e)))?;

            batch_stmts.push((query, decoded_args));
        }

        let result = TOKIO_RUNTIME.block_on(async {
            let mut all_results: Vec<Term<'a>> = Vec::new();

            // Execute each statement sequentially
            for (sql, args) in batch_stmts.iter() {
                let client_guard = safe_lock_arc(&client, "execute_batch client")?;
                let conn_guard = safe_lock_arc(&client_guard.client, "execute_batch conn")?;

                match conn_guard.query(sql, args.clone()).await {
                    Ok(rows) => {
                        let collected = collect_rows(env, rows)
                            .await
                            .map_err(|e| rustler::Error::Term(Box::new(format!("{:?}", e))))?;
                        all_results.push(collected);
                    }
                    Err(e) => {
                        return Err(rustler::Error::Term(Box::new(format!(
                            "Batch statement error: {}",
                            e
                        ))));
                    }
                }
            }

            // Check if we need to sync
            // NOTE: LibSQL automatically syncs writes to remote for embedded replicas.
            // No manual sync needed here.

            Ok(Ok(all_results.encode(env)))
        });

        return result;
    } else {
        Err(rustler::Error::Term(Box::new("Invalid connection ID")))
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn execute_transactional_batch<'a>(
    env: Env<'a>,
    conn_id: &str,
    _mode: Atom,
    _syncx: Atom,
    statements: Vec<Term<'a>>,
) -> Result<NifResult<Term<'a>>, rustler::Error> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "execute_transactional_batch conn_map")?;

    if let Some(client) = conn_map.get(conn_id) {
        let client = client.clone();

        // Decode each statement with its arguments
        let mut batch_stmts: Vec<(String, Vec<Value>)> = Vec::new();
        for stmt_term in statements {
            let (query, args): (String, Vec<Term>) = stmt_term.decode().map_err(|e| {
                rustler::Error::Term(Box::new(format!("Failed to decode statement: {:?}", e)))
            })?;

            let decoded_args: Vec<Value> = args
                .into_iter()
                .map(|t| decode_term_to_value(t))
                .collect::<Result<_, _>>()
                .map_err(|e| rustler::Error::Term(Box::new(e)))?;

            batch_stmts.push((query, decoded_args));
        }

        let result = TOKIO_RUNTIME.block_on(async {
            // Start a transaction
            let client_guard = safe_lock_arc(&client, "execute_transactional_batch client")?;
            let conn_guard =
                safe_lock_arc(&client_guard.client, "execute_transactional_batch conn")?;

            let trx = conn_guard.transaction().await.map_err(|e| {
                rustler::Error::Term(Box::new(format!("Begin transaction failed: {}", e)))
            })?;

            let mut all_results: Vec<Term<'a>> = Vec::new();

            // Execute each statement in the transaction
            for (sql, args) in batch_stmts.iter() {
                match trx.query(sql, args.clone()).await {
                    Ok(rows) => {
                        let collected = collect_rows(env, rows)
                            .await
                            .map_err(|e| rustler::Error::Term(Box::new(format!("{:?}", e))))?;
                        all_results.push(collected);
                    }
                    Err(e) => {
                        // Rollback on error
                        let _ = trx.rollback().await;
                        return Err(rustler::Error::Term(Box::new(format!(
                            "Batch statement error: {}",
                            e
                        ))));
                    }
                }
            }

            // Commit the transaction
            trx.commit()
                .await
                .map_err(|e| rustler::Error::Term(Box::new(format!("Commit failed: {}", e))))?;

            // Sync if needed
            // NOTE: LibSQL automatically syncs writes to remote for embedded replicas.
            // No manual sync needed here.

            Ok(Ok(all_results.encode(env)))
        });

        return result;
    } else {
        Err(rustler::Error::Term(Box::new("Invalid connection ID")))
    }
}

// Prepared statement support
#[rustler::nif(schedule = "DirtyIo")]
fn prepare_statement(conn_id: &str, sql: &str) -> NifResult<String> {
    let client = {
        let conn_map = safe_lock(&CONNECTION_REGISTRY, "prepare_statement conn_map")?;
        conn_map
            .get(conn_id)
            .cloned()
            .ok_or_else(|| rustler::Error::Term(Box::new("Invalid connection ID")))?
    };
    {
        let sql_to_prepare = sql.to_string();

        let stmt_result = TOKIO_RUNTIME.block_on(async {
            let client_guard = safe_lock_arc(&client, "prepare_statement client")?;
            let conn_guard = safe_lock_arc(&client_guard.client, "prepare_statement conn")?;

            conn_guard
                .prepare(&sql_to_prepare)
                .await
                .map_err(|e| rustler::Error::Term(Box::new(format!("Prepare failed: {}", e))))
        });

        match stmt_result {
            Ok(stmt) => {
                let stmt_id = Uuid::new_v4().to_string();
                safe_lock(&STMT_REGISTRY, "prepare_statement stmt_registry")?.insert(
                    stmt_id.clone(),
                    (conn_id.to_string(), Arc::new(Mutex::new(stmt))),
                );
                Ok(stmt_id)
            }
            Err(e) => Err(e),
        }
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn query_prepared<'a>(
    env: Env<'a>,
    conn_id: &str,
    stmt_id: &str,
    _mode: Atom,
    _syncx: Atom,
    args: Vec<Term<'a>>,
) -> Result<NifResult<Term<'a>>, rustler::Error> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "query_prepared conn_map")?;
    let stmt_registry = safe_lock(&STMT_REGISTRY, "query_prepared stmt_registry")?;

    if conn_map.get(conn_id).is_none() {
        return Err(rustler::Error::Term(Box::new("Invalid connection ID")));
    }

    let (stored_conn_id, cached_stmt) = stmt_registry
        .get(stmt_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Statement not found")))?;

    // Verify statement belongs to this connection
    verify_statement_ownership(stored_conn_id, conn_id)?;

    let cached_stmt = cached_stmt.clone();

    let decoded_args: Vec<Value> = args
        .into_iter()
        .map(|t| decode_term_to_value(t))
        .collect::<Result<_, _>>()
        .map_err(|e| rustler::Error::Term(Box::new(e)))?;

    drop(stmt_registry); // Release lock before async operation
    drop(conn_map); // Release lock before async operation

    let result = TOKIO_RUNTIME.block_on(async {
        // Use cached statement with reset to clear bindings
        let stmt_guard = safe_lock_arc(&cached_stmt, "query_prepared stmt")?;

        // Reset clears any previous bindings
        stmt_guard.reset();

        let res = stmt_guard.query(decoded_args).await;

        match res {
            Ok(rows) => {
                let collected = collect_rows(env, rows)
                    .await
                    .map_err(|e| rustler::Error::Term(Box::new(format!("{:?}", e))))?;

                Ok(Ok(collected))
            }
            Err(e) => Err(rustler::Error::Term(Box::new(e.to_string()))),
        }
    });

    result
}

#[rustler::nif(schedule = "DirtyIo")]
#[allow(unused_variables)]
fn execute_prepared<'a>(
    env: Env<'a>,
    conn_id: &str,
    stmt_id: &str,
    mode: Atom,
    syncx: Atom,
    sql_hint: &str, // For detecting if we need sync
    args: Vec<Term<'a>>,
) -> NifResult<u64> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "execute_prepared conn_map")?;
    let stmt_registry = safe_lock(&STMT_REGISTRY, "execute_prepared stmt_registry")?;

    if conn_map.get(conn_id).is_none() {
        return Err(rustler::Error::Term(Box::new("Invalid connection ID")));
    }

    let (stored_conn_id, cached_stmt) = stmt_registry
        .get(stmt_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Statement not found")))?;

    // Verify statement belongs to this connection
    verify_statement_ownership(stored_conn_id, conn_id)?;

    let cached_stmt = cached_stmt.clone();

    let decoded_args: Vec<Value> = args
        .into_iter()
        .map(|t| decode_term_to_value(t))
        .collect::<Result<_, _>>()
        .map_err(|e| rustler::Error::Term(Box::new(e)))?;

    let _is_sync = !matches!(detect_query_type(sql_hint), QueryType::Select);

    drop(stmt_registry); // Release lock before async operation
    drop(conn_map); // Release lock before async operation

    let result = TOKIO_RUNTIME.block_on(async {
        // Use cached statement with reset to clear bindings
        let stmt_guard = safe_lock_arc(&cached_stmt, "execute_prepared stmt")?;

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

// Metadata methods
#[rustler::nif(schedule = "DirtyIo")]
fn last_insert_rowid(conn_id: &str) -> NifResult<i64> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "last_insert_rowid conn_map")?;

    if let Some(client) = conn_map.get(conn_id) {
        let client = client.clone();

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

#[rustler::nif(schedule = "DirtyIo")]
fn changes(conn_id: &str) -> NifResult<u64> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "changes conn_map")?;

    if let Some(client) = conn_map.get(conn_id) {
        let client = client.clone();

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

#[rustler::nif(schedule = "DirtyIo")]
fn total_changes(conn_id: &str) -> NifResult<u64> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "total_changes conn_map")?;

    if let Some(client) = conn_map.get(conn_id) {
        let client = client.clone();

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

#[rustler::nif(schedule = "DirtyIo")]
fn is_autocommit(conn_id: &str) -> NifResult<bool> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "is_autocommit conn_map")?;

    if let Some(client) = conn_map.get(conn_id) {
        let client = client.clone();

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

// Cursor support for large result sets
#[rustler::nif(schedule = "DirtyIo")]
fn declare_cursor(conn_id: &str, sql: &str, args: Vec<Term>) -> NifResult<String> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "declare_cursor conn_map")?;

    if let Some(client) = conn_map.get(conn_id) {
        let client = client.clone();

        let decoded_args: Vec<Value> = args
            .into_iter()
            .map(|t| decode_term_to_value(t))
            .collect::<Result<_, _>>()
            .map_err(|e| rustler::Error::Term(Box::new(e)))?;

        let (columns, rows) = TOKIO_RUNTIME.block_on(async {
            let client_guard = safe_lock_arc(&client, "declare_cursor client")?;
            let conn_guard = safe_lock_arc(&client_guard.client, "declare_cursor conn")?;

            let mut result_rows = conn_guard
                .query(sql, decoded_args)
                .await
                .map_err(|e| rustler::Error::Term(Box::new(format!("Query failed: {}", e))))?;

            let mut columns: Vec<String> = Vec::new();
            let mut rows: Vec<Vec<Value>> = Vec::new();

            while let Some(row) = result_rows
                .next()
                .await
                .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?
            {
                // Get column names on first row
                if columns.is_empty() {
                    for i in 0..row.column_count() {
                        if let Some(name) = row.column_name(i) {
                            columns.push(name.to_string());
                        } else {
                            columns.push(format!("col{}", i));
                        }
                    }
                }

                // Collect row values
                let mut row_values = Vec::new();
                for i in 0..columns.len() {
                    let value = row.get(i as i32).unwrap_or(Value::Null);
                    row_values.push(value);
                }
                rows.push(row_values);
            }

            Ok::<_, rustler::Error>((columns, rows))
        })?;

        let cursor_id = Uuid::new_v4().to_string();
        let cursor_data = CursorData {
            conn_id: conn_id.to_string(),
            columns,
            rows,
            position: 0,
        };

        safe_lock(&CURSOR_REGISTRY, "declare_cursor cursor_registry")?
            .insert(cursor_id.clone(), cursor_data);

        Ok(cursor_id)
    } else {
        Err(rustler::Error::Term(Box::new("Invalid connection ID")))
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn declare_cursor_with_context(
    id: &str,
    id_type: Atom,
    sql: &str,
    args: Vec<Term>,
) -> NifResult<String> {
    let decoded_args: Vec<Value> = args
        .into_iter()
        .map(|t| decode_term_to_value(t))
        .collect::<Result<_, _>>()
        .map_err(|e| rustler::Error::Term(Box::new(e)))?;

    let (conn_id, columns, rows) = if id_type == transaction() {
        // CONSOLIDATED LOCK SCOPE: Prevent TOCTOU by holding lock for both conn_id lookup and query execution
        let mut txn_registry = safe_lock(&TXN_REGISTRY, "declare_cursor_with_context txn")?;
        let entry = txn_registry
            .get_mut(id)
            .ok_or_else(|| rustler::Error::Term(Box::new("Transaction not found")))?;

        // Capture conn_id while we hold the lock
        let conn_id_for_cursor = entry.conn_id.clone();

        // Execute query without releasing the lock
        let (cols, rows) = TOKIO_RUNTIME.block_on(async {
            let mut result_rows = entry
                .transaction
                .query(sql, decoded_args)
                .await
                .map_err(|e| rustler::Error::Term(Box::new(format!("Query failed: {}", e))))?;

            let mut columns: Vec<String> = Vec::new();
            let mut rows: Vec<Vec<Value>> = Vec::new();

            while let Some(row) = result_rows
                .next()
                .await
                .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?
            {
                if columns.is_empty() {
                    for i in 0..row.column_count() {
                        if let Some(name) = row.column_name(i) {
                            columns.push(name.to_string());
                        } else {
                            columns.push(format!("col{}", i));
                        }
                    }
                }

                let mut row_values = Vec::new();
                for i in 0..columns.len() {
                    let value = row.get(i as i32).unwrap_or(Value::Null);
                    row_values.push(value);
                }
                rows.push(row_values);
            }

            Ok::<_, rustler::Error>((columns, rows))
        })?;

        (conn_id_for_cursor, cols, rows)
    } else if id_type == connection() {
        // For connection, use the id directly
        let conn_id_for_cursor = id.to_string();
        let conn_map = safe_lock(&CONNECTION_REGISTRY, "declare_cursor_with_context conn")?;
        let client = conn_map
            .get(id)
            .ok_or_else(|| rustler::Error::Term(Box::new("Connection not found")))?
            .clone();

        drop(conn_map);

        let (cols, rows) = TOKIO_RUNTIME.block_on(async {
            let client_guard = safe_lock_arc(&client, "declare_cursor_with_context client")?;
            let conn_guard =
                safe_lock_arc(&client_guard.client, "declare_cursor_with_context conn")?;

            let mut result_rows = conn_guard
                .query(sql, decoded_args)
                .await
                .map_err(|e| rustler::Error::Term(Box::new(format!("Query failed: {}", e))))?;

            let mut columns: Vec<String> = Vec::new();
            let mut rows: Vec<Vec<Value>> = Vec::new();

            while let Some(row) = result_rows
                .next()
                .await
                .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?
            {
                if columns.is_empty() {
                    for i in 0..row.column_count() {
                        if let Some(name) = row.column_name(i) {
                            columns.push(name.to_string());
                        } else {
                            columns.push(format!("col{}", i));
                        }
                    }
                }

                let mut row_values = Vec::new();
                for i in 0..columns.len() {
                    let value = row.get(i as i32).unwrap_or(Value::Null);
                    row_values.push(value);
                }
                rows.push(row_values);
            }

            Ok::<_, rustler::Error>((columns, rows))
        })?;

        (conn_id_for_cursor, cols, rows)
    } else {
        return Err(rustler::Error::Term(Box::new("Invalid id_type for cursor")));
    };

    let cursor_id = Uuid::new_v4().to_string();
    let cursor_data = CursorData {
        conn_id,
        columns,
        rows,
        position: 0,
    };

    safe_lock(&CURSOR_REGISTRY, "declare_cursor_with_context cursor")?
        .insert(cursor_id.clone(), cursor_data);

    Ok(cursor_id)
}

#[rustler::nif]
fn fetch_cursor<'a>(
    env: Env<'a>,
    conn_id: &str,
    cursor_id: &str,
    max_rows: usize,
) -> NifResult<Term<'a>> {
    let mut cursor_registry = safe_lock(&CURSOR_REGISTRY, "fetch_cursor cursor_registry")?;

    let cursor = cursor_registry
        .get_mut(cursor_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Cursor not found")))?;

    // Verify cursor belongs to this connection
    verify_cursor_ownership(cursor, conn_id)?;

    let remaining = cursor.rows.len().saturating_sub(cursor.position);
    let fetch_count = remaining.min(max_rows);

    if fetch_count == 0 {
        // No more rows
        let elixir_columns: Vec<Term> = cursor.columns.iter().map(|c| c.encode(env)).collect();
        let empty_rows: Vec<Term> = Vec::new();
        let result = (elixir_columns, empty_rows, 0usize);
        return Ok(result.encode(env));
    }

    let end_pos = cursor.position + fetch_count;
    let fetched_rows: Vec<Vec<Value>> = cursor.rows[cursor.position..end_pos].to_vec();
    cursor.position = end_pos;

    // Convert to Elixir terms
    let elixir_columns: Vec<Term> = cursor.columns.iter().map(|c| c.encode(env)).collect();

    let elixir_rows: Vec<Term> = fetched_rows
        .iter()
        .map(|row| {
            let row_terms: Vec<Term> = row
                .iter()
                .map(|val| match val {
                    Value::Text(s) => s.encode(env),
                    Value::Integer(i) => i.encode(env),
                    Value::Real(f) => f.encode(env),
                    Value::Blob(b) => match OwnedBinary::new(b.len()) {
                        Some(mut owned) => {
                            owned.as_mut_slice().copy_from_slice(b);
                            Binary::from_owned(owned, env).encode(env)
                        }
                        None => nil().encode(env),
                    },
                    Value::Null => nil().encode(env),
                })
                .collect();
            row_terms.encode(env)
        })
        .collect();

    let result = (elixir_columns, elixir_rows, fetch_count);
    Ok(result.encode(env))
}

/// Set the busy timeout for the connection.
/// This controls how long SQLite waits for locks before returning SQLITE_BUSY.
/// Default SQLite behavior is to return immediately; setting a timeout allows
/// for better concurrency handling.
#[rustler::nif(schedule = "DirtyIo")]
fn set_busy_timeout(conn_id: &str, timeout_ms: u64) -> NifResult<rustler::Atom> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "set_busy_timeout conn_map")?;

    if let Some(client) = conn_map.get(conn_id) {
        let client = client.clone();
        drop(conn_map); // Release lock before blocking operation

        let result = TOKIO_RUNTIME.block_on(async {
            let client_guard = safe_lock_arc(&client, "set_busy_timeout client")?;
            let conn_guard = safe_lock_arc(&client_guard.client, "set_busy_timeout conn")?;

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

/// Reset the connection state.
/// This clears any prepared statements and resets the connection to a clean state.
/// Useful for connection pooling to ensure connections are clean when returned to pool.
#[rustler::nif(schedule = "DirtyIo")]
fn reset_connection(conn_id: &str) -> NifResult<rustler::Atom> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "reset_connection conn_map")?;

    if let Some(client) = conn_map.get(conn_id) {
        let client = client.clone();
        drop(conn_map); // Release lock before blocking operation

        TOKIO_RUNTIME.block_on(async {
            let client_guard = safe_lock_arc(&client, "reset_connection client")?;
            let conn_guard = safe_lock_arc(&client_guard.client, "reset_connection conn")?;

            conn_guard.reset().await;
            Ok::<(), rustler::Error>(())
        })?;

        Ok(rustler::types::atom::ok())
    } else {
        Err(rustler::Error::Term(Box::new("Invalid connection ID")))
    }
}

/// Interrupt any ongoing operation on this connection.
/// Causes the current operation to return at the earliest opportunity.
/// Useful for cancelling long-running queries.
#[rustler::nif(schedule = "DirtyIo")]
fn interrupt_connection(conn_id: &str) -> NifResult<rustler::Atom> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "interrupt_connection conn_map")?;

    if let Some(client) = conn_map.get(conn_id) {
        let client = client.clone();
        drop(conn_map); // Release lock before operation

        let client_guard = safe_lock_arc(&client, "interrupt_connection client")?;
        let conn_guard = safe_lock_arc(&client_guard.client, "interrupt_connection conn")?;

        conn_guard
            .interrupt()
            .map_err(|e| rustler::Error::Term(Box::new(format!("interrupt failed: {}", e))))?;

        Ok(rustler::types::atom::ok())
    } else {
        Err(rustler::Error::Term(Box::new("Invalid connection ID")))
    }
}

/// Execute a PRAGMA statement and return the result.
/// PRAGMA statements are SQLite's configuration mechanism.
///
/// Common PRAGMA statements:
/// - `PRAGMA foreign_keys = ON` - Enable foreign key constraints
/// - `PRAGMA journal_mode = WAL` - Set write-ahead logging mode
/// - `PRAGMA synchronous = NORMAL` - Set synchronisation level
/// - `PRAGMA busy_timeout = 5000` - Set busy timeout (though prefer set_busy_timeout NIF)
///
/// Some PRAGMAs return values (e.g., `PRAGMA foreign_keys`), others just set values.
#[rustler::nif(schedule = "DirtyIo")]
fn pragma_query<'a>(env: Env<'a>, conn_id: &str, pragma_stmt: &str) -> NifResult<Term<'a>> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "pragma_query conn_map")?;

    if let Some(client) = conn_map.get(conn_id) {
        let client = client.clone();
        drop(conn_map); // Release lock before async operation

        let result = TOKIO_RUNTIME.block_on(async {
            let client_guard = safe_lock_arc(&client, "pragma_query client")?;
            let conn_guard = safe_lock_arc(&client_guard.client, "pragma_query conn")?;

            let rows = conn_guard.query(pragma_stmt, ()).await.map_err(|e| {
                rustler::Error::Term(Box::new(format!("PRAGMA query failed: {}", e)))
            })?;

            collect_rows(env, rows).await
        });

        result
    } else {
        Err(rustler::Error::Term(Box::new("Invalid connection ID")))
    }
}

/// Execute multiple SQL statements from a single string (semicolon-separated).
/// Uses LibSQL's native batch execution for better performance.
/// Each statement is executed independently - if one fails, others may still complete.
#[rustler::nif(schedule = "DirtyIo")]
fn execute_batch_native<'a>(env: Env<'a>, conn_id: &str, sql: &str) -> NifResult<Term<'a>> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "execute_batch_native conn_map")?;

    if let Some(client) = conn_map.get(conn_id) {
        let client = client.clone();
        drop(conn_map); // Release lock before async operation

        let result = TOKIO_RUNTIME.block_on(async {
            let client_guard = safe_lock_arc(&client, "execute_batch_native client")?;
            let conn_guard = safe_lock_arc(&client_guard.client, "execute_batch_native conn")?;

            let mut batch_rows = conn_guard
                .execute_batch(sql)
                .await
                .map_err(|e| rustler::Error::Term(Box::new(format!("batch failed: {}", e))))?;

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
/// Uses LibSQL's native transactional batch execution.
/// All statements succeed or all are rolled back.
#[rustler::nif(schedule = "DirtyIo")]
fn execute_transactional_batch_native<'a>(
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
                        rustler::Error::Term(Box::new(format!("transactional batch failed: {}", e)))
                    })?;

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

/// Get the number of columns in a prepared statement's result set.
/// Returns 0 for statements that don't return rows (INSERT, UPDATE, DELETE).
#[rustler::nif(schedule = "DirtyIo")]
fn statement_column_count(conn_id: &str, stmt_id: &str) -> NifResult<usize> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "statement_column_count conn_map")?;
    let stmt_registry = safe_lock(&STMT_REGISTRY, "statement_column_count stmt_registry")?;

    if conn_map.get(conn_id).is_none() {
        return Err(rustler::Error::Term(Box::new("Invalid connection ID")));
    }

    let (stored_conn_id, cached_stmt) = stmt_registry
        .get(stmt_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Statement not found")))?;

    // Verify statement belongs to this connection
    verify_statement_ownership(stored_conn_id, conn_id)?;

    let cached_stmt = cached_stmt.clone();

    drop(stmt_registry);
    drop(conn_map);

    let stmt_guard = safe_lock_arc(&cached_stmt, "statement_column_count stmt")?;
    let count = stmt_guard.column_count();

    Ok(count)
}

/// Get the name of a column in a prepared statement by its index.
/// Index is 0-based. Returns error if index is out of bounds.
#[rustler::nif(schedule = "DirtyIo")]
fn statement_column_name(conn_id: &str, stmt_id: &str, idx: usize) -> NifResult<String> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "statement_column_name conn_map")?;
    let stmt_registry = safe_lock(&STMT_REGISTRY, "statement_column_name stmt_registry")?;

    if conn_map.get(conn_id).is_none() {
        return Err(rustler::Error::Term(Box::new("Invalid connection ID")));
    }

    let (stored_conn_id, cached_stmt) = stmt_registry
        .get(stmt_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Statement not found")))?;

    // Verify statement belongs to this connection
    verify_statement_ownership(stored_conn_id, conn_id)?;

    let cached_stmt = cached_stmt.clone();

    drop(stmt_registry);
    drop(conn_map);

    let stmt_guard = safe_lock_arc(&cached_stmt, "statement_column_name stmt")?;
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
/// Parameters are placeholders (?) in the SQL.
#[rustler::nif(schedule = "DirtyIo")]
fn statement_parameter_count(conn_id: &str, stmt_id: &str) -> NifResult<usize> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "statement_parameter_count conn_map")?;
    let stmt_registry = safe_lock(&STMT_REGISTRY, "statement_parameter_count stmt_registry")?;

    if conn_map.get(conn_id).is_none() {
        return Err(rustler::Error::Term(Box::new("Invalid connection ID")));
    }

    let (stored_conn_id, cached_stmt) = stmt_registry
        .get(stmt_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Statement not found")))?;

    // Verify statement belongs to this connection
    verify_statement_ownership(stored_conn_id, conn_id)?;

    let cached_stmt = cached_stmt.clone();

    drop(stmt_registry);
    drop(conn_map);

    let stmt_guard = safe_lock_arc(&cached_stmt, "statement_parameter_count stmt")?;
    let count = stmt_guard.parameter_count();

    Ok(count)
}

/// Validate that a savepoint name is a valid SQL identifier.
/// Must be non-empty, ASCII alphanumeric + underscore, and not start with a digit.
fn validate_savepoint_name(name: &str) -> Result<(), rustler::Error> {
    if name.is_empty()
        || !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
        || name.chars().next().map_or(true, |c| c.is_ascii_digit())
    {
        return Err(rustler::Error::Term(Box::new(
            "Invalid savepoint name: must be a valid SQL identifier",
        )));
    }
    Ok(())
}

/// Create a savepoint within a transaction.
/// Savepoints allow partial rollback without aborting the entire transaction.
///
/// NOTE: Validates that the transaction belongs to the requesting connection.
#[rustler::nif(schedule = "DirtyIo")]
fn savepoint(conn_id: &str, trx_id: &str, name: &str) -> NifResult<Atom> {
    validate_savepoint_name(name)?;

    let mut txn_registry = safe_lock(&TXN_REGISTRY, "savepoint")?;

    let entry = txn_registry
        .get_mut(trx_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Transaction not found")))?;

    // Verify that the transaction belongs to the requesting connection
    if entry.conn_id != conn_id {
        return Err(rustler::Error::Term(Box::new(
            "Transaction does not belong to this connection",
        )));
    }

    let sql = format!("SAVEPOINT {}", name);

    TOKIO_RUNTIME
        .block_on(async { entry.transaction.execute(&sql, Vec::<Value>::new()).await })
        .map_err(|e| rustler::Error::Term(Box::new(format!("Savepoint failed: {}", e))))?;

    Ok(rustler::types::atom::ok())
}

/// Release (commit) a savepoint, making its changes permanent within the transaction.
///
/// Security: Validates that the transaction belongs to the requesting connection.
#[rustler::nif(schedule = "DirtyIo")]
fn release_savepoint(conn_id: &str, trx_id: &str, name: &str) -> NifResult<Atom> {
    validate_savepoint_name(name)?;

    let mut txn_registry = safe_lock(&TXN_REGISTRY, "release_savepoint")?;

    let entry = txn_registry
        .get_mut(trx_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Transaction not found")))?;

    // Verify that the transaction belongs to the requesting connection
    if entry.conn_id != conn_id {
        return Err(rustler::Error::Term(Box::new(
            "Transaction does not belong to this connection",
        )));
    }

    let sql = format!("RELEASE SAVEPOINT {}", name);

    TOKIO_RUNTIME
        .block_on(async { entry.transaction.execute(&sql, Vec::<Value>::new()).await })
        .map_err(|e| rustler::Error::Term(Box::new(format!("Release savepoint failed: {}", e))))?;

    Ok(rustler::types::atom::ok())
}

/// Rollback to a savepoint, undoing all changes made after the savepoint was created.
/// The savepoint remains active and can be released or rolled back to again.
///
/// Security: Validates that the transaction belongs to the requesting connection.
#[rustler::nif(schedule = "DirtyIo")]
fn rollback_to_savepoint(conn_id: &str, trx_id: &str, name: &str) -> NifResult<Atom> {
    validate_savepoint_name(name)?;

    let mut txn_registry = safe_lock(&TXN_REGISTRY, "rollback_to_savepoint")?;

    let entry = txn_registry
        .get_mut(trx_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Transaction not found")))?;

    // Verify that the transaction belongs to the requesting connection
    if entry.conn_id != conn_id {
        return Err(rustler::Error::Term(Box::new(
            "Transaction does not belong to this connection",
        )));
    }

    let sql = format!("ROLLBACK TO SAVEPOINT {}", name);

    TOKIO_RUNTIME
        .block_on(async { entry.transaction.execute(&sql, Vec::<Value>::new()).await })
        .map_err(|e| {
            rustler::Error::Term(Box::new(format!("Rollback to savepoint failed: {}", e)))
        })?;

    Ok(rustler::types::atom::ok())
}

/// Get the current replication index (frame number) from a remote replica database.
/// Returns the frame number or 0 if not a replica or no frames have been applied yet.
///
/// **Note**: This function now uses the `replication_index()` API available in libsql 0.9.29+.
#[rustler::nif(schedule = "DirtyIo")]
fn get_frame_number(conn_id: &str) -> NifResult<u64> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "get_frame_number conn_map")?;
    let client = conn_map
        .get(conn_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Connection not found")))?
        .clone();
    drop(conn_map);

    let result = TOKIO_RUNTIME.block_on(async {
        let client_guard = safe_lock_arc(&client, "get_frame_number client")
            .map_err(|e| format!("Failed to lock client: {:?}", e))?;

        let frame_no = client_guard
            .db
            .replication_index()
            .await
            .map_err(|e| format!("replication_index failed: {}", e))?;

        Ok::<_, String>(frame_no.unwrap_or(0))
    });

    match result {
        Ok(frame_no) => Ok(frame_no),
        Err(e) => Err(rustler::Error::Term(Box::new(e))),
    }
}

/// Sync the remote replica until a specific frame number is reached.
/// Waits (with timeout) for the replica to catch up to the target frame.
#[rustler::nif(schedule = "DirtyIo")]
fn sync_until(conn_id: &str, frame_no: u64) -> NifResult<Atom> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "sync_until conn_map")?;
    let client = conn_map
        .get(conn_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Connection not found")))?
        .clone();
    drop(conn_map);

    let result = TOKIO_RUNTIME.block_on(async {
        let client_guard = safe_lock_arc(&client, "sync_until client")
            .map_err(|e| format!("Failed to lock client: {:?}", e))?;

        let timeout_duration = tokio::time::Duration::from_secs(DEFAULT_SYNC_TIMEOUT_SECS);
        tokio::time::timeout(timeout_duration, client_guard.db.sync_until(frame_no))
            .await
            .map_err(|_| {
                format!(
                    "sync_until timed out after {} seconds",
                    DEFAULT_SYNC_TIMEOUT_SECS
                )
            })?
            .map_err(|e| format!("sync_until failed: {}", e))?;

        Ok::<_, String>(())
    });

    match result {
        Ok(()) => Ok(rustler::types::atom::ok()),
        Err(e) => Err(rustler::Error::Term(Box::new(e))),
    }
}

/// Flush the replicator, pushing pending writes to the remote database.
/// Returns the new frame number after flush.
#[rustler::nif(schedule = "DirtyIo")]
fn flush_replicator(conn_id: &str) -> NifResult<u64> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "flush_replicator conn_map")?;
    let client = conn_map
        .get(conn_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Connection not found")))?
        .clone();
    drop(conn_map);

    let result: Result<u64, String> = TOKIO_RUNTIME.block_on(async {
        let client_guard = safe_lock_arc(&client, "flush_replicator client")
            .map_err(|e| format!("Failed to lock client: {:?}", e))?;

        let timeout_duration = tokio::time::Duration::from_secs(DEFAULT_SYNC_TIMEOUT_SECS);
        let frame_no = tokio::time::timeout(timeout_duration, client_guard.db.flush_replicator())
            .await
            .map_err(|_| {
                format!(
                    "flush_replicator timed out after {} seconds",
                    DEFAULT_SYNC_TIMEOUT_SECS
                )
            })?
            .map_err(|e| format!("flush_replicator failed: {}", e))?;

        // Return 0 if not a replica (consistent with get_frame_number behavior)
        Ok(frame_no.unwrap_or(0))
    });

    match result {
        Ok(frame_no) => Ok(frame_no),
        Err(e) => Err(rustler::Error::Term(Box::new(e))),
    }
}

/// Get the highest frame number from write operations on this database.
/// This is useful for read-your-writes consistency across replicas.
///
/// Returns Some(frame_no) if write operations have occurred, None otherwise.
/// Note: This returns None (mapped to 0) rather than an error for databases
/// that don't track write replication index.
#[rustler::nif(schedule = "DirtyIo")]
fn max_write_replication_index(conn_id: &str) -> NifResult<u64> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "max_write_replication_index conn_map")?;
    let client = conn_map
        .get(conn_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Connection not found")))?
        .clone();
    drop(conn_map);

    let result = TOKIO_RUNTIME.block_on(async {
        let client_guard = safe_lock_arc(&client, "max_write_replication_index client")
            .map_err(|e| format!("Failed to lock client: {:?}", e))?;

        // Call max_write_replication_index() which returns Option<FrameNo>
        let max_write_frame = client_guard.db.max_write_replication_index();

        Ok::<_, String>(max_write_frame.unwrap_or(0))
    });

    match result {
        Ok(frame_no) => Ok(frame_no),
        Err(e) => Err(rustler::Error::Term(Box::new(e))),
    }
}

// Note: sync_frames requires complex Frames type, skipping for now
// Can be added later if needed with proper frame data marshalling

/// **NOT SUPPORTED** - Freeze database operation is not implemented.
///
/// Freeze is intended to convert a remote replica to a standalone local database
/// for disaster recovery. However, this operation requires deep refactoring of
/// the connection pool architecture (taking ownership of the Database instance,
/// which is held in an Arc within connection state, etc.) and is not currently
/// supported.
///
/// Returns: `:unsupported` atom error via NIF
#[rustler::nif(schedule = "DirtyIo")]
fn freeze_database(conn_id: &str) -> NifResult<Atom> {
    // Verify connection exists (basic validation)
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "freeze_database conn_map")?;
    let _exists = conn_map
        .get(conn_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Connection not found")))?;
    drop(conn_map);

    // Always return :unsupported atom - this feature requires architectural changes
    // that have not been completed. See CLAUDE.md for implementation details.
    // Note: We return this as a string error that Elixir will convert to :unsupported atom
    Err(rustler::Error::Atom("unsupported"))
}

rustler::init!("Elixir.EctoLibSql.Native");

#[cfg(test)]
mod tests;
