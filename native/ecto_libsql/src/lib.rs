use bytes::Bytes;
use lazy_static::lazy_static;
use libsql::{Builder, Cipher, EncryptionConfig, Rows, Transaction, TransactionBehavior, Value};
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
    pub columns: Vec<String>,
    pub rows: Vec<Vec<Value>>,
    pub position: usize,
}

lazy_static! {
    static ref TXN_REGISTRY: Mutex<HashMap<String, Transaction>> = Mutex::new(HashMap::new());
    static ref STMT_REGISTRY: Mutex<HashMap<String, (String, String)>> = Mutex::new(HashMap::new()); // (conn_id, sql)
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
        safe_lock(&TXN_REGISTRY, "begin_transaction txn_registry")?.insert(trx_id.clone(), trx);

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
        safe_lock(
            &TXN_REGISTRY,
            "begin_transaction_with_behavior txn_registry",
        )?
        .insert(trx_id.clone(), trx);

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
    query: &str,
    args: Vec<Term<'a>>,
) -> NifResult<u64> {
    let mut txn_registry = safe_lock(&TXN_REGISTRY, "execute_with_transaction")?;

    let trx = txn_registry
        .get_mut(trx_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Transaction not found")))?;
    let decoded_args: Vec<Value> = args
        .into_iter()
        .map(|t| decode_term_to_value(t))
        .collect::<Result<_, _>>()
        .map_err(|e| rustler::Error::Term(Box::new(e)))?;

    let result = TOKIO_RUNTIME
        .block_on(async { trx.execute(&query, decoded_args).await })
        .map_err(|e| rustler::Error::Term(Box::new(format!("Execute failed: {}", e))))?;

    Ok(result)
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn query_with_trx_args<'a>(
    env: Env<'a>,
    trx_id: &str,
    query: &str,
    args: Vec<Term<'a>>,
) -> NifResult<Term<'a>> {
    let mut txn_registry = safe_lock(&TXN_REGISTRY, "query_with_trx_args")?;

    let trx = txn_registry
        .get_mut(trx_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Transaction not found")))?;
    let decoded_args: Vec<Value> = args
        .into_iter()
        .map(|t| decode_term_to_value(t))
        .collect::<Result<_, _>>()
        .map_err(|e| rustler::Error::Term(Box::new(e)))?;

    TOKIO_RUNTIME.block_on(async {
        let res_rows = trx
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
    _conn_id: &str,
    _mode: Atom,
    _syncx: Atom,
    param: &str,
) -> NifResult<(rustler::Atom, String)> {
    let trx = safe_lock(&TXN_REGISTRY, "commit_or_rollback txn_registry")?
        .remove(trx_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Transaction not found")))?;

    let result = TOKIO_RUNTIME.block_on(async {
        if param == "commit" {
            trx.commit()
                .await
                .map_err(|e| format!("Commit error: {}", e))?;
        } else {
            trx.rollback()
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
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "prepare_statement conn_map")?;

    if conn_map.get(conn_id).is_some() {
        // Store the connection ID and SQL for later re-preparation
        let stmt_id = Uuid::new_v4().to_string();
        safe_lock(&STMT_REGISTRY, "prepare_statement stmt_registry")?
            .insert(stmt_id.clone(), (conn_id.to_string(), sql.to_string()));

        Ok(stmt_id)
    } else {
        Err(rustler::Error::Term(Box::new("Invalid connection ID")))
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

    let (_stored_conn_id, sql) = stmt_registry
        .get(stmt_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Statement not found")))?;

    let client = conn_map
        .get(conn_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Connection not found")))?
        .clone();
    let sql = sql.clone();

    let decoded_args: Vec<Value> = args
        .into_iter()
        .map(|t| decode_term_to_value(t))
        .collect::<Result<_, _>>()
        .map_err(|e| rustler::Error::Term(Box::new(e)))?;

    drop(stmt_registry); // Release lock before async operation
    drop(conn_map); // Release lock before async operation

    let result = TOKIO_RUNTIME.block_on(async {
        // Re-prepare the statement for each query to avoid parameter binding issues
        let client_guard = safe_lock_arc(&client, "query_prepared client")?;
        let conn_guard = safe_lock_arc(&client_guard.client, "query_prepared conn")?;

        let stmt = conn_guard
            .prepare(&sql)
            .await
            .map_err(|e| rustler::Error::Term(Box::new(format!("Prepare failed: {}", e))))?;

        let res = stmt.query(decoded_args).await;

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

    let client = conn_map
        .get(conn_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Connection not found")))?
        .clone();
    let (_stored_conn_id, sql) = stmt_registry
        .get(stmt_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Statement not found")))?;

    let sql = sql.clone();

    let decoded_args: Vec<Value> = args
        .into_iter()
        .map(|t| decode_term_to_value(t))
        .collect::<Result<_, _>>()
        .map_err(|e| rustler::Error::Term(Box::new(e)))?;

    let _is_sync = !matches!(detect_query_type(sql_hint), QueryType::Select);

    drop(stmt_registry); // Release lock before async operation
    drop(conn_map); // Release lock before async operation

    let result = TOKIO_RUNTIME.block_on(async {
        // Re-prepare the statement for each execute to avoid parameter binding issues
        let client_guard = safe_lock_arc(&client, "execute_prepared client")?;
        let conn_guard = safe_lock_arc(&client_guard.client, "execute_prepared conn")?;

        let stmt = conn_guard
            .prepare(&sql)
            .await
            .map_err(|e| rustler::Error::Term(Box::new(format!("Prepare failed: {}", e))))?;

        let affected = stmt
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

    let (columns, rows) = if id_type == transaction() {
        // Use transaction registry
        let mut txn_registry = safe_lock(&TXN_REGISTRY, "declare_cursor_with_context txn")?;
        let trx = txn_registry
            .get_mut(id)
            .ok_or_else(|| rustler::Error::Term(Box::new("Transaction not found")))?;

        TOKIO_RUNTIME.block_on(async {
            let mut result_rows = trx
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
        })?
    } else {
        // Use connection registry
        let conn_map = safe_lock(&CONNECTION_REGISTRY, "declare_cursor_with_context conn")?;
        let client = conn_map
            .get(id)
            .ok_or_else(|| rustler::Error::Term(Box::new("Connection not found")))?
            .clone();

        drop(conn_map);

        TOKIO_RUNTIME.block_on(async {
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
        })?
    };

    let cursor_id = Uuid::new_v4().to_string();
    let cursor_data = CursorData {
        columns,
        rows,
        position: 0,
    };

    safe_lock(&CURSOR_REGISTRY, "declare_cursor_with_context cursor")?
        .insert(cursor_id.clone(), cursor_data);

    Ok(cursor_id)
}

#[rustler::nif]
fn fetch_cursor<'a>(env: Env<'a>, cursor_id: &str, max_rows: usize) -> NifResult<Term<'a>> {
    let mut cursor_registry = safe_lock(&CURSOR_REGISTRY, "fetch_cursor cursor_registry")?;

    let cursor = cursor_registry
        .get_mut(cursor_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Cursor not found")))?;

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

rustler::init!("Elixir.EctoLibSql.Native");

#[cfg(test)]
mod tests;
