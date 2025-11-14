use bytes::Bytes;
use lazy_static::lazy_static;
use libsql::{
    Builder, Cipher, EncryptionConfig, Rows, Statement, Transaction, TransactionBehavior, Value,
};
use once_cell::sync::Lazy;
use rustler::atoms;
use rustler::types::atom::nil;
use rustler::{resource_impl, Atom, Encoder, Env, NifResult, Resource, Term};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use tokio::runtime::Runtime;
use uuid::Uuid;

static TOKIO_RUNTIME: Lazy<Runtime> =
    Lazy::new(|| Runtime::new().expect("Failed to create Tokio runtime"));

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
    static ref STMT_REGISTRY: Mutex<HashMap<String, Statement>> = Mutex::new(HashMap::new());
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
    read_only
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
    let conn_map = CONNECTION_REGISTRY.lock().unwrap();
    if let Some(conn) = conn_map.get(conn_id) {
        let trx = TOKIO_RUNTIME
            .block_on(async {
                conn.lock()
                    .unwrap()
                    .client
                    .lock()
                    .unwrap()
                    .transaction()
                    .await
            })
            .map_err(|e| rustler::Error::Term(Box::new(format!("Begin failed: {}", e))))?;

        let trx_id = Uuid::new_v4().to_string();
        TXN_REGISTRY.lock().unwrap().insert(trx_id.clone(), trx);

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
    let conn_map = CONNECTION_REGISTRY.lock().unwrap();
    if let Some(conn) = conn_map.get(conn_id) {
        let trx_behavior =
            decode_transaction_behavior(behavior).unwrap_or(TransactionBehavior::Deferred);

        let trx = TOKIO_RUNTIME
            .block_on(async {
                conn.lock()
                    .unwrap()
                    .client
                    .lock()
                    .unwrap()
                    .transaction_with_behavior(trx_behavior)
                    .await
            })
            .map_err(|e| rustler::Error::Term(Box::new(format!("Begin failed: {}", e))))?;

        let trx_id = Uuid::new_v4().to_string();
        TXN_REGISTRY.lock().unwrap().insert(trx_id.clone(), trx);

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
    let mut txn_registry = TXN_REGISTRY.lock().unwrap();

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
pub fn handle_status_transaction(trx_id: &str) -> NifResult<rustler::Atom> {
    let trx_registy = TXN_REGISTRY.lock().unwrap();
    let trx = trx_registy.get(trx_id);

    match trx {
        Some(_) => return Ok(rustler::types::atom::ok()),

        None => return Err(rustler::Error::Term(Box::new("Transaction not found"))),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn do_sync(conn_id: &str, mode: Atom) -> NifResult<(rustler::Atom, String)> {
    let conn_map = CONNECTION_REGISTRY.lock().unwrap();
    let client = conn_map
        .get(conn_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Connection not found")))?;

    let result = TOKIO_RUNTIME.block_on(async {
        if matches!(decode_mode(mode), Some(Mode::RemoteReplica)) {
            client
                .lock()
                .unwrap()
                .db
                .sync()
                .await
                .map_err(|e| format!("Sync error: {}", e))?;
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
    mode: Atom,
    syncx: Atom,
    param: &str,
) -> NifResult<(rustler::Atom, String)> {
    let trx = TXN_REGISTRY
        .lock()
        .unwrap()
        .remove(trx_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Transaction not found")))?;

    let conn_map = CONNECTION_REGISTRY.lock().unwrap();
    let client = conn_map
        .get(conn_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Connection not found")))?;

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
        if matches!(decode_mode(mode), Some(Mode::RemoteReplica)) && syncx == enable_sync() {
            client
                .lock()
                .unwrap()
                .db
                .sync()
                .await
                .map_err(|e| format!("Sync error: {}", e))?;
        }
        //else
        //no sync

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
        let removed = CONNECTION_REGISTRY.lock().unwrap().remove(id);
        match removed {
            Some(_) => Ok(rustler::types::atom::ok()),
            None => Err(rustler::Error::Term(Box::new("Connection not found"))),
        }
    } else if opt == trx_id() {
        let removed = TXN_REGISTRY.lock().unwrap().remove(id);
        match removed {
            Some(_) => Ok(rustler::types::atom::ok()),
            None => Err(rustler::Error::Term(Box::new("Transaction not found"))),
        }
    } else if opt == stmt_id() {
        let removed = STMT_REGISTRY.lock().unwrap().remove(id);
        match removed {
            Some(_) => Ok(rustler::types::atom::ok()),
            None => Err(rustler::Error::Term(Box::new("Statement not found"))),
        }
    } else if opt == cursor_id() {
        let removed = CURSOR_REGISTRY.lock().unwrap().remove(id);
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

    rt.block_on(async {
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

        if mode.atom_to_string().unwrap() != "local" {
            conn.query("SELECT 1", ())
                .await
                .map_err(|e| rustler::Error::Term(Box::new(format!("Failed ping: {}", e))))?;
        }

        let libsql_conn = Arc::new(Mutex::new(LibSQLConn {
            db,
            client: Arc::new(Mutex::new(conn)),
        }));

        let conn_id = Uuid::new_v4().to_string();
        CONNECTION_REGISTRY
            .lock()
            .unwrap()
            .insert(conn_id.clone(), libsql_conn);

        Ok(conn_id)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn query_args<'a>(
    env: Env<'a>,
    conn_id: &str,
    mode: Atom,
    syncx: Atom,
    query: &str,
    args: Vec<Term<'a>>,
) -> Result<NifResult<Term<'a>>, rustler::Error> {
    let conn_map = CONNECTION_REGISTRY.lock().unwrap();

    let is_sync = !matches!(detect_query_type(query), QueryType::Select);

    if let Some(client) = conn_map.get(conn_id) {
        let client = client.clone();

        let params: Result<Vec<Value>, _> =
            args.into_iter().map(|t| decode_term_to_value(t)).collect();

        let params = params.map_err(|e| rustler::Error::Term(Box::new(e)))?;

        let result = TOKIO_RUNTIME.block_on(async {
            let res = client
                .lock()
                .unwrap()
                .client
                .lock()
                .unwrap()
                .query(query, params)
                .await;

            match res {
                Ok(res_rows) => {
                    let res = collect_rows(env, res_rows)
                        .await
                        .map_err(|e| rustler::Error::Term(Box::new(format!("{:?}", e))));

                    if let Some(modex) = decode_mode(mode) {
                        // if remote replica and a write query then sync
                        if matches!(modex, Mode::RemoteReplica) && is_sync && syncx == enable_sync()
                        {
                            let _ = client.lock().unwrap().db.sync().await;
                        }
                    }

                    return Ok(res);
                }

                Err(e) => Err(rustler::Error::Term(Box::new(e.to_string()))),
            }
        });

        return result;
    } else {
        println!("query args Connection ID not found: {}", conn_id);
        Err(rustler::Error::Term(Box::new("Invalid connection ID")))
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn ping(conn_id: String) -> NifResult<bool> {
    let conn_map = CONNECTION_REGISTRY.lock().unwrap();

    let maybe_conn = conn_map.get(&conn_id);
    if let Some(conn) = maybe_conn {
        let client = conn.clone();

        let result = TOKIO_RUNTIME.block_on(async {
            client
                .lock()
                .unwrap()
                .client
                .lock()
                .unwrap()
                .query("SELECT 1", ())
                .await
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
    } else if let Ok(v) = term.decode::<bool>() {
        Ok(Value::Integer(if v { 1 } else { 0 }))
    } else if let Ok(v) = term.decode::<String>() {
        Ok(Value::Text(v))
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
                Ok(Value::Blob(val)) => val.encode(env),
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

pub fn decode_term_to_valuex(term: Term) -> Result<Value, String> {
    if let Ok(v) = term.decode::<i64>() {
        Ok(Value::Integer(v))
    } else if let Ok(v) = term.decode::<bool>() {
        Ok(Value::Integer(if v { 1 } else { 0 }))
    } else if let Ok(v) = term.decode::<String>() {
        Ok(Value::Text(v))
    } else if let Ok(v) = term.decode::<Vec<u8>>() {
        //Ok(Value::Blob(v))
        //
        if v.len() == 16 {
            match Uuid::from_slice(&v) {
                Ok(uuid) => Ok(Value::Text(uuid.to_string())),
                Err(_) => Ok(Value::Blob(v)), // fallback
            }
        } else {
            Ok(Value::Blob(v))
        }
    } else {
        Err(format!("Unsupported argument type: {:?}", term))
    }
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
    mode: Atom,
    syncx: Atom,
    statements: Vec<Term<'a>>,
) -> Result<NifResult<Term<'a>>, rustler::Error> {
    let conn_map = CONNECTION_REGISTRY.lock().unwrap();

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
                match client
                    .lock()
                    .unwrap()
                    .client
                    .lock()
                    .unwrap()
                    .query(sql, args.clone())
                    .await
                {
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
            let needs_sync = batch_stmts.iter().any(|(sql, _)| {
                matches!(
                    detect_query_type(sql),
                    QueryType::Insert
                        | QueryType::Update
                        | QueryType::Delete
                        | QueryType::Create
                        | QueryType::Drop
                        | QueryType::Alter
                )
            });

            if needs_sync {
                if let Some(modex) = decode_mode(mode) {
                    if matches!(modex, Mode::RemoteReplica) && syncx == enable_sync() {
                        let _ = client.lock().unwrap().db.sync().await;
                    }
                }
            }

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
    mode: Atom,
    syncx: Atom,
    statements: Vec<Term<'a>>,
) -> Result<NifResult<Term<'a>>, rustler::Error> {
    let conn_map = CONNECTION_REGISTRY.lock().unwrap();

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
            let trx = client
                .lock()
                .unwrap()
                .client
                .lock()
                .unwrap()
                .transaction()
                .await
                .map_err(|e| {
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
            let needs_sync = batch_stmts.iter().any(|(sql, _)| {
                matches!(
                    detect_query_type(sql),
                    QueryType::Insert
                        | QueryType::Update
                        | QueryType::Delete
                        | QueryType::Create
                        | QueryType::Drop
                        | QueryType::Alter
                )
            });

            if needs_sync {
                if let Some(modex) = decode_mode(mode) {
                    if matches!(modex, Mode::RemoteReplica) && syncx == enable_sync() {
                        let _ = client.lock().unwrap().db.sync().await;
                    }
                }
            }

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
    let conn_map = CONNECTION_REGISTRY.lock().unwrap();

    if let Some(client) = conn_map.get(conn_id) {
        let client = client.clone();

        let stmt = TOKIO_RUNTIME
            .block_on(async {
                client
                    .lock()
                    .unwrap()
                    .client
                    .lock()
                    .unwrap()
                    .prepare(sql)
                    .await
            })
            .map_err(|e| rustler::Error::Term(Box::new(format!("Prepare failed: {}", e))))?;

        let stmt_id = Uuid::new_v4().to_string();
        STMT_REGISTRY.lock().unwrap().insert(stmt_id.clone(), stmt);

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
    let conn_map = CONNECTION_REGISTRY.lock().unwrap();
    let mut stmt_registry = STMT_REGISTRY.lock().unwrap();

    if conn_map.get(conn_id).is_none() {
        return Err(rustler::Error::Term(Box::new("Invalid connection ID")));
    }
    let stmt = stmt_registry
        .get_mut(stmt_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Statement not found")))?;

    let decoded_args: Vec<Value> = args
        .into_iter()
        .map(|t| decode_term_to_value(t))
        .collect::<Result<_, _>>()
        .map_err(|e| rustler::Error::Term(Box::new(e)))?;

    let result = TOKIO_RUNTIME.block_on(async {
        let res = stmt.query(decoded_args).await;

        match res {
            Ok(rows) => {
                let collected = collect_rows(env, rows)
                    .await
                    .map_err(|e| rustler::Error::Term(Box::new(format!("{:?}", e))))?;

                // Note: Prepared statements don't auto-sync by default
                // Users should explicitly sync if needed

                Ok(Ok(collected))
            }
            Err(e) => Err(rustler::Error::Term(Box::new(e.to_string()))),
        }
    });

    result
}

#[rustler::nif(schedule = "DirtyIo")]
fn execute_prepared<'a>(
    conn_id: &str,
    stmt_id: &str,
    mode: Atom,
    syncx: Atom,
    args: Vec<Term<'a>>,
    sql_hint: &str, // For detecting if we need sync
) -> NifResult<u64> {
    let conn_map = CONNECTION_REGISTRY.lock().unwrap();
    let mut stmt_registry = STMT_REGISTRY.lock().unwrap();

    if conn_map.get(conn_id).is_none() {
        return Err(rustler::Error::Term(Box::new("Invalid connection ID")));
    }

    let client = conn_map.get(conn_id).unwrap().clone();
    let stmt = stmt_registry
        .get_mut(stmt_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Statement not found")))?;

    let decoded_args: Vec<Value> = args
        .into_iter()
        .map(|t| decode_term_to_value(t))
        .collect::<Result<_, _>>()
        .map_err(|e| rustler::Error::Term(Box::new(e)))?;

    let is_sync = !matches!(detect_query_type(sql_hint), QueryType::Select);

    let result = TOKIO_RUNTIME.block_on(async {
        let affected = stmt
            .execute(decoded_args)
            .await
            .map_err(|e| rustler::Error::Term(Box::new(format!("Execute failed: {}", e))))?;

        // Auto-sync if needed
        if is_sync {
            if let Some(modex) = decode_mode(mode) {
                if matches!(modex, Mode::RemoteReplica) && syncx == enable_sync() {
                    let _ = client.lock().unwrap().db.sync().await;
                }
            }
        }

        Ok(affected as u64)
    });

    result
}

// Metadata methods
#[rustler::nif(schedule = "DirtyIo")]
fn last_insert_rowid(conn_id: &str) -> NifResult<i64> {
    let conn_map = CONNECTION_REGISTRY.lock().unwrap();

    if let Some(client) = conn_map.get(conn_id) {
        let client = client.clone();

        let result = TOKIO_RUNTIME.block_on(async {
            client
                .lock()
                .unwrap()
                .client
                .lock()
                .unwrap()
                .last_insert_rowid()
        });

        Ok(result)
    } else {
        Err(rustler::Error::Term(Box::new("Invalid connection ID")))
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn changes(conn_id: &str) -> NifResult<u64> {
    let conn_map = CONNECTION_REGISTRY.lock().unwrap();

    if let Some(client) = conn_map.get(conn_id) {
        let client = client.clone();

        let result = TOKIO_RUNTIME
            .block_on(async { client.lock().unwrap().client.lock().unwrap().changes() });

        Ok(result)
    } else {
        Err(rustler::Error::Term(Box::new("Invalid connection ID")))
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn total_changes(conn_id: &str) -> NifResult<u64> {
    let conn_map = CONNECTION_REGISTRY.lock().unwrap();

    if let Some(client) = conn_map.get(conn_id) {
        let client = client.clone();

        let result = TOKIO_RUNTIME.block_on(async {
            client
                .lock()
                .unwrap()
                .client
                .lock()
                .unwrap()
                .total_changes()
        });

        Ok(result)
    } else {
        Err(rustler::Error::Term(Box::new("Invalid connection ID")))
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn is_autocommit(conn_id: &str) -> NifResult<bool> {
    let conn_map = CONNECTION_REGISTRY.lock().unwrap();

    if let Some(client) = conn_map.get(conn_id) {
        let client = client.clone();

        let result = TOKIO_RUNTIME.block_on(async {
            client
                .lock()
                .unwrap()
                .client
                .lock()
                .unwrap()
                .is_autocommit()
        });

        Ok(result)
    } else {
        Err(rustler::Error::Term(Box::new("Invalid connection ID")))
    }
}

// Cursor support for large result sets
#[rustler::nif(schedule = "DirtyIo")]
fn declare_cursor(conn_id: &str, sql: &str, args: Vec<Term>) -> NifResult<String> {
    let conn_map = CONNECTION_REGISTRY.lock().unwrap();

    if let Some(client) = conn_map.get(conn_id) {
        let client = client.clone();

        let decoded_args: Vec<Value> = args
            .into_iter()
            .map(|t| decode_term_to_value(t))
            .collect::<Result<_, _>>()
            .map_err(|e| rustler::Error::Term(Box::new(e)))?;

        let (columns, rows) = TOKIO_RUNTIME.block_on(async {
            let mut result_rows = client
                .lock()
                .unwrap()
                .client
                .lock()
                .unwrap()
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

        CURSOR_REGISTRY
            .lock()
            .unwrap()
            .insert(cursor_id.clone(), cursor_data);

        Ok(cursor_id)
    } else {
        Err(rustler::Error::Term(Box::new("Invalid connection ID")))
    }
}

#[rustler::nif]
fn fetch_cursor<'a>(env: Env<'a>, cursor_id: &str, max_rows: usize) -> NifResult<Term<'a>> {
    let mut cursor_registry = CURSOR_REGISTRY.lock().unwrap();

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
                    Value::Blob(b) => b.encode(env),
                    Value::Null => nil().encode(env),
                })
                .collect();
            row_terms.encode(env)
        })
        .collect();

    let result = (elixir_columns, elixir_rows, fetch_count);
    Ok(result.encode(env))
}

rustler::init!("Elixir.LibSqlEx.Native");
