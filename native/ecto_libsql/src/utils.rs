/// Utility functions and helpers for EctoLibSql
///
/// This module provides commonly used helper functions for locking, error handling,
/// value conversion, and result processing.
use crate::models::LibSQLConn;
use libsql::{Rows, Value};
use rustler::types::atom::nil;
use rustler::{Binary, Encoder, Env, OwnedBinary, Term};
use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

/// Safely lock a mutex with proper error handling
///
/// Returns a descriptive error message if the mutex is poisoned.
pub fn safe_lock<'a, T>(
    mutex: &'a Mutex<T>,
    context: &str,
) -> Result<MutexGuard<'a, T>, rustler::Error> {
    mutex
        .lock()
        .map_err(|e| rustler::Error::Term(Box::new(format!("Mutex poisoned in {context}: {e}"))))
}

/// Safely lock an Arc<Mutex<T>> with proper error handling
///
/// Returns a descriptive error message if the mutex is poisoned.
pub fn safe_lock_arc<'a, T>(
    arc_mutex: &'a Arc<Mutex<T>>,
    context: &str,
) -> Result<MutexGuard<'a, T>, rustler::Error> {
    arc_mutex.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!("Arc mutex poisoned in {context}: {e}")))
    })
}

/// Perform sync with timeout for remote replicas
///
/// Executes a sync operation with a configurable timeout.
///
/// # Note on Lock Safety
/// This function holds a std::sync::Mutex guard across an await point. This is intentional
/// and safe because it is called within TOKIO_RUNTIME.block_on() which executes synchronously.
#[allow(clippy::await_holding_lock)]
pub async fn sync_with_timeout(
    client: &Arc<Mutex<LibSQLConn>>,
    timeout_secs: u64,
) -> Result<(), String> {
    let timeout = Duration::from_secs(timeout_secs);

    tokio::time::timeout(timeout, async {
        let client_guard =
            safe_lock_arc(client, "sync_with_timeout client").map_err(|e| format!("{e:?}"))?;
        client_guard
            .db
            .sync()
            .await
            .map_err(|e| format!("Sync error: {e}"))?;
        Ok::<_, String>(())
    })
    .await
    .map_err(|_| format!("Sync timeout after {timeout_secs} seconds"))?
}

/// Build an empty result map for write operations (INSERT/UPDATE/DELETE without RETURNING)
///
/// Used when a statement doesn't return rows, only an affected row count.
/// The result shape matches `collect_rows` format.
pub fn build_empty_result<'a>(env: Env<'a>, rows_affected: u64) -> Term<'a> {
    let mut result_map: HashMap<String, Term<'a>> = HashMap::with_capacity(3);
    result_map.insert("columns".to_string(), Vec::<Term>::new().encode(env));
    result_map.insert("rows".to_string(), Vec::<Term>::new().encode(env));
    result_map.insert("num_rows".to_string(), rows_affected.encode(env));
    result_map.encode(env)
}

/// Enhance constraint error messages with actual index names
///
/// SQLite only reports column names in constraint errors, not index/constraint names.
/// This function queries SQLite metadata to find the actual index name and enhances
/// the error message to include it, making it compatible with Ecto's unique_constraint/3.
///
/// For example, it transforms:
///   "UNIQUE constraint failed: users.email"
/// Into:
///   "UNIQUE constraint failed: users.email (index: users_email_index)"
pub async fn enhance_constraint_error(
    conn: &libsql::Connection,
    error_message: &str,
) -> Result<String, String> {
    // Check if this is a unique constraint error
    if !error_message.contains("UNIQUE constraint failed:") {
        return Ok(error_message.to_string());
    }

    // Extract table and column names from the error message
    let constraint_part = error_message
        .split("UNIQUE constraint failed:")
        .nth(1)
        .unwrap_or("")
        .trim()
        .trim_matches('`')
        .trim();

    // Parse table name and columns
    let parts: Vec<&str> = constraint_part.split(',').collect();
    let first_part = parts[0].trim();
    let table_and_col: Vec<&str> = first_part.split('.').collect();

    if table_and_col.len() < 2 {
        return Ok(error_message.to_string());
    }

    let table_name = table_and_col[0].trim();
    let columns: Vec<String> = parts
        .iter()
        .map(|part| {
            let split: Vec<&str> = part.trim().split('.').collect();
            split.last().copied().unwrap_or("").to_string()
        })
        .collect();

    // Helper function to quote SQLite identifiers safely
    let quote_identifier = |id: &str| -> String {
        // Escape any double quotes by doubling them, then wrap in double quotes
        format!("\"{}\"", id.replace("\"", "\"\""))
    };

    // Query SQLite for unique indexes on this table
    let pragma_query = format!("PRAGMA index_list({})", quote_identifier(table_name));
    let params: Vec<Value> = vec![];
    let mut rows = conn
        .query(&pragma_query, params)
        .await
        .map_err(|e| format!("Failed to query index list: {e}"))?;

    // Find unique indexes and check their columns
    while let Some(row) = rows
        .next()
        .await
        .map_err(|e| format!("Failed to read index list row: {e}"))?
    {
        // Column 1 is the index name, column 2 is unique flag
        let index_name: String = row
            .get(1)
            .map_err(|e| format!("Failed to get index name: {e}"))?;
        let is_unique: i64 = row
            .get(2)
            .map_err(|e| format!("Failed to get unique flag: {e}"))?;

        if is_unique != 1 {
            continue;
        }

        // Query the columns in this index
        let info_query = format!("PRAGMA index_info({})", quote_identifier(&index_name));
        let info_params: Vec<Value> = vec![];
        let mut info_rows = conn
            .query(&info_query, info_params)
            .await
            .map_err(|e| format!("Failed to query index info: {e}"))?;

        let mut index_columns = Vec::new();
        while let Some(info_row) = info_rows
            .next()
            .await
            .map_err(|e| format!("Failed to read index info row: {e}"))?
        {
            // Column 2 is the column name
            let col_name: String = info_row
                .get(2)
                .map_err(|e| format!("Failed to get column name: {e}"))?;
            index_columns.push(col_name);
        }

        // Check if this index's columns match the constraint violation
        if index_columns == columns {
            // Found the matching index! Enhance the error message
            return Ok(format!(
                "{} (index: {})",
                error_message.trim_end_matches('`').trim_end(),
                index_name
            ));
        }
    }

    // No matching index found, return original error
    Ok(error_message.to_string())
}

/// Collect rows from a query result into a map of columns and rows
///
/// Processes async row iterator and converts LibSQL values to Elixir terms.
pub async fn collect_rows<'a>(env: Env<'a>, mut rows: Rows) -> Result<Term<'a>, rustler::Error> {
    let mut column_names: Vec<String> = Vec::new();
    let mut collected_rows: Vec<Vec<Term<'a>>> = Vec::new();
    let mut column_count: usize = 0;

    while let Some(row_result) = rows
        .next()
        .await
        .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?
    {
        if column_names.is_empty() {
            column_count = row_result.column_count() as usize;
            for i in 0..column_count {
                if let Some(name) = row_result.column_name(i as i32) {
                    column_names.push(name.to_string());
                } else {
                    column_names.push(format!("col{i}"));
                }
            }
        }

        let mut row_terms = Vec::with_capacity(column_count);
        for i in 0..column_names.len() {
            let term = match row_result.get(i as i32) {
                Ok(Value::Text(val)) => val.encode(env),
                Ok(Value::Integer(val)) => val.encode(env),
                Ok(Value::Real(val)) => val.encode(env),
                Ok(Value::Blob(val)) => OwnedBinary::new(val.len())
                    .ok_or_else(|| {
                        let col_name = column_names
                            .get(i)
                            .unwrap_or(&"unknown".to_string())
                            .clone();
                        rustler::Error::Term(Box::new(format!(
                            "Failed to allocate binary for column '{col_name}' (index {i})"
                        )))
                    })
                    .map(|mut owned| {
                        owned.as_mut_slice().copy_from_slice(&val);
                        Binary::from_owned(owned, env).encode(env)
                    })?,
                Ok(Value::Null) => nil().encode(env),
                Err(err) => {
                    let col_name = column_names
                        .get(i)
                        .unwrap_or(&"unknown".to_string())
                        .clone();
                    return Err(rustler::Error::Term(Box::new(format!(
                        "Failed to read column '{col_name}' (index {i}): {err}"
                    ))));
                }
            };
            row_terms.push(term);
        }
        collected_rows.push(row_terms);
    }

    let encoded_columns: Vec<Term> = column_names.iter().map(|c| c.encode(env)).collect();
    let encoded_rows: Vec<Term> = collected_rows.iter().map(|r| r.encode(env)).collect();

    let mut result_map: HashMap<String, Term<'a>> = HashMap::with_capacity(3);
    result_map.insert("columns".to_string(), encoded_columns.encode(env));
    result_map.insert("rows".to_string(), encoded_rows.encode(env));
    result_map.insert(
        "num_rows".to_string(),
        (collected_rows.len() as u64).encode(env),
    );

    Ok(result_map.encode(env))
}

/// Query type enumeration for dispatching queries vs. executions
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

/// Detect the query type from a SQL statement
///
/// Examines the first keyword to categorize the statement.
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

/// Determines if a query should use query() or execute()
///
/// Returns true if should use query() (SELECT or has RETURNING clause).
///
/// Performance optimisations:
/// - Zero allocations (no to_uppercase())
/// - Single-pass byte scanning
/// - Early termination on match
/// - Case-insensitive ASCII comparison without allocations
///
/// ## Limitation: String and Comment Handling
///
/// This function performs simple keyword matching and does not parse SQL syntax.
/// It will match keywords appearing in string literals or comments.
///
/// **Why this is acceptable**:
/// - False positives (using `query()` when `execute()` would suffice) are **safe**
/// - False negatives (using `execute()` for statements that return rows) would **fail**
/// - Full SQL parsing would be prohibitively expensive
#[inline]
pub fn should_use_query(sql: &str) -> bool {
    let bytes = sql.as_bytes();
    let len = bytes.len();

    if len == 0 {
        return false;
    }

    // Find first non-whitespace character
    let mut start = 0;
    while start < len && bytes[start].is_ascii_whitespace() {
        start += 1;
    }

    if start >= len {
        return false;
    }

    // Check if starts with SELECT (case-insensitive)
    if len - start >= 6
        && (bytes[start] == b'S' || bytes[start] == b's')
        && (bytes[start + 1] == b'E' || bytes[start + 1] == b'e')
        && (bytes[start + 2] == b'L' || bytes[start + 2] == b'l')
        && (bytes[start + 3] == b'E' || bytes[start + 3] == b'e')
        && (bytes[start + 4] == b'C' || bytes[start + 4] == b'c')
        && (bytes[start + 5] == b'T' || bytes[start + 5] == b't')
        // Verify it's followed by whitespace or end of string
        && (start + 6 >= len || bytes[start + 6].is_ascii_whitespace())
    {
        return true;
    }

    // Check for RETURNING clause (case-insensitive)
    if len >= 9 {
        let target = b"RETURNING";
        let mut i = 0;

        while i <= len - 9 {
            // Only check if preceded by whitespace or it's at the start
            if i == 0 || bytes[i - 1].is_ascii_whitespace() {
                let mut matches = true;
                for j in 0..9 {
                    let c = bytes[i + j];
                    let t = target[j];
                    // Case-insensitive comparison for ASCII
                    if c != t && c != t.to_ascii_lowercase() {
                        matches = false;
                        break;
                    }
                }

                if matches {
                    // Verify it's followed by whitespace or end of string
                    if i + 9 >= len || bytes[i + 9].is_ascii_whitespace() {
                        return true;
                    }
                }
            }
            i += 1;
        }
    }

    false
}

/// Decode an Elixir term to a LibSQL Value
///
/// Supports integers, floats, booleans, strings, blobs, nil/null, and binary data.
pub fn decode_term_to_value(term: Term) -> Result<Value, String> {
    use crate::constants::{blob, nil};

    // Check for nil atom first (represents NULL in SQL)
    if let Ok(atom) = term.decode::<rustler::Atom>() {
        if atom == nil() {
            return Ok(Value::Null);
        }
        // If it's not nil, it might be a boolean or other atom type
        // Let boolean decoding handle true/false below
    }

    if let Ok(v) = term.decode::<i64>() {
        Ok(Value::Integer(v))
    } else if let Ok(v) = term.decode::<f64>() {
        Ok(Value::Real(v))
    } else if let Ok(v) = term.decode::<bool>() {
        Ok(Value::Integer(if v { 1 } else { 0 }))
    } else if let Ok(v) = term.decode::<String>() {
        Ok(Value::Text(v))
    } else if let Ok((atom, data)) = term.decode::<(rustler::Atom, Vec<u8>)>() {
        // Handle {:blob, data} tuple from Ecto binary dumper
        if atom == blob() {
            Ok(Value::Blob(data))
        } else {
            Err(format!("Unsupported atom tuple: {atom:?}"))
        }
    } else if let Ok(v) = term.decode::<Binary>() {
        // Handle Elixir binaries (including BLOBs)
        Ok(Value::Blob(v.as_slice().to_vec()))
    } else if let Ok(v) = term.decode::<Vec<u8>>() {
        Ok(Value::Blob(v))
    } else {
        Err(format!("Unsupported argument type: {term:?}"))
    }
}
