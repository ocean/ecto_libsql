/// Cursor and streaming operations for LibSQL databases.
///
/// This module handles cursor-based result set streaming, including:
/// - Declaring cursors for large result sets
/// - Fetching rows from cursors in batches
/// - Memory-efficient iteration over large result sets
/// - Cursor ownership verification
///
/// Cursors allow processing large result sets without loading everything into memory at once.
/// Results are fetched in configurable batch sizes for efficient memory usage.
use crate::{
    constants::{CONNECTION_REGISTRY, CURSOR_REGISTRY, TOKIO_RUNTIME},
    decode,
    models::CursorData,
    transaction::TransactionEntryGuard,
    utils,
};
use libsql::Value;
use rustler::{Atom, Binary, Encoder, Env, NifResult, OwnedBinary, Term};

/// Declare a cursor for streaming result set from a connection.
///
/// This executes a query and stores all results in a cursor, which can then
/// be fetched in batches using `fetch_cursor`.
///
/// # Arguments
/// - `conn_id`: Database connection ID
/// - `sql`: SQL query string
/// - `args`: Query parameters
///
/// Returns a cursor ID on success, error on failure.
#[rustler::nif(schedule = "DirtyIo")]
pub fn declare_cursor(conn_id: &str, sql: &str, args: Vec<Term>) -> NifResult<String> {
    let conn_map = utils::safe_lock(&CONNECTION_REGISTRY, "declare_cursor conn_map")?;

    let client = conn_map
        .get(conn_id)
        .cloned()
        .ok_or_else(|| rustler::Error::Term(Box::new("Invalid connection ID")))?;

    drop(conn_map); // Release lock before async operation

    let decoded_args: Vec<Value> = args
        .into_iter()
        .map(|t| utils::decode_term_to_value(t))
        .collect::<Result<_, _>>()
        .map_err(|e| rustler::Error::Term(Box::new(e)))?;

    // SAFETY: We're inside TOKIO_RUNTIME.block_on(), so this is synchronous execution.
    // The std::sync::Mutex guards are safe to hold across await points here because
    // we're not in a true async context - block_on runs the future to completion.
    #[allow(clippy::await_holding_lock)]
    let (columns, rows) = TOKIO_RUNTIME.block_on(async {
        let client_guard = utils::safe_lock_arc(&client, "declare_cursor client")?;
        let conn_guard = utils::safe_lock_arc(&client_guard.client, "declare_cursor conn")?;

        let mut result_rows = conn_guard
            .query(sql, decoded_args)
            .await
            .map_err(|e| rustler::Error::Term(Box::new(format!("Query failed: {e}"))))?;

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

    let cursor_id = uuid::Uuid::new_v4().to_string();
    let cursor_data = CursorData {
        conn_id: conn_id.to_string(),
        columns,
        rows,
        position: 0,
    };

    utils::safe_lock(&CURSOR_REGISTRY, "declare_cursor cursor_registry")?
        .insert(cursor_id.clone(), cursor_data);

    Ok(cursor_id)
}

/// Declare a cursor from within a transaction or connection context.
///
/// This is a specialized version that can accept either a transaction ID or connection ID,
/// allowing cursors to be created within transaction contexts.
///
/// # Arguments
/// - `conn_id`: Connection ID (used for ownership validation)
/// - `id`: Transaction ID or connection ID
/// - `id_type`: Atom indicating whether `id` is a transaction (`:transaction`) or connection (`:connection`)
/// - `sql`: SQL query string
/// - `args`: Query parameters
///
/// Returns a cursor ID on success, error on failure.
#[rustler::nif(schedule = "DirtyIo")]
pub fn declare_cursor_with_context(
    conn_id: &str,
    id: &str,
    id_type: Atom,
    sql: &str,
    args: Vec<Term>,
) -> NifResult<String> {
    let decoded_args: Vec<Value> = args
        .into_iter()
        .map(|t| utils::decode_term_to_value(t))
        .collect::<Result<_, _>>()
        .map_err(|e| rustler::Error::Term(Box::new(e)))?;

    let (cursor_conn_id, columns, rows) = if id_type == crate::constants::transaction() {
        // Take transaction entry with ownership verification using guard
        let guard = TransactionEntryGuard::take(id, conn_id)?;

        // Capture conn_id for cursor ownership
        let cursor_conn_id = conn_id.to_string();

        // Execute query without holding the lock
        let (cols, rows) = TOKIO_RUNTIME.block_on(async {
            let mut result_rows = guard
                .transaction()?
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

        // Guard automatically re-inserts the entry on drop

        (cursor_conn_id, cols, rows)
    } else if id_type == crate::constants::connection() {
        // For connection, verify that the provided conn_id matches the id
        if conn_id != id {
            return Err(rustler::Error::Term(Box::new(
                "Connection ID mismatch: provided conn_id does not match cursor connection ID",
            )));
        }

        let cursor_conn_id = id.to_string();
        let client = {
            let conn_map =
                utils::safe_lock(&CONNECTION_REGISTRY, "declare_cursor_with_context conn")?;
            conn_map
                .get(id)
                .cloned()
                .ok_or_else(|| rustler::Error::Term(Box::new("Connection not found")))?
        }; // Lock dropped here

        // Clone the inner connection Arc and drop the outer lock before async operations
        let connection = {
            let client_guard = utils::safe_lock_arc(&client, "declare_cursor_with_context client")?;
            client_guard.client.clone()
        }; // Outer lock dropped here

        // SAFETY: We're inside TOKIO_RUNTIME.block_on(), so this is synchronous execution.
        // The std::sync::Mutex guards are safe to hold across await points here because
        // we're not in a true async context - block_on runs the future to completion.
        #[allow(clippy::await_holding_lock)]
        let (cols, rows) = TOKIO_RUNTIME.block_on(async {
            let conn_guard = utils::safe_lock_arc(&connection, "declare_cursor_with_context conn")?;

            let mut result_rows = conn_guard
                .query(sql, decoded_args)
                .await
                .map_err(|e| rustler::Error::Term(Box::new(format!("Query failed: {e}"))))?;

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

        (cursor_conn_id, cols, rows)
    } else {
        return Err(rustler::Error::Term(Box::new("Invalid id_type for cursor")));
    };

    let cursor_id = uuid::Uuid::new_v4().to_string();
    let cursor_data = CursorData {
        conn_id: cursor_conn_id,
        columns,
        rows,
        position: 0,
    };

    utils::safe_lock(&CURSOR_REGISTRY, "declare_cursor_with_context cursor")?
        .insert(cursor_id.clone(), cursor_data);

    Ok(cursor_id)
}

/// Fetch rows from a cursor in batches.
///
/// Returns up to `max_rows` rows from the cursor's current position.
/// The cursor position is automatically advanced. When no more rows are available,
/// returns an empty result set.
///
/// # Arguments
/// - `env`: Elixir environment
/// - `conn_id`: Connection ID (for ownership verification)
/// - `cursor_id`: Cursor ID
/// - `max_rows`: Maximum number of rows to fetch
///
/// Returns a tuple of (columns, rows, row_count)
#[rustler::nif(schedule = "DirtyIo")]
pub fn fetch_cursor<'a>(
    env: Env<'a>,
    conn_id: &str,
    cursor_id: &str,
    max_rows: usize,
) -> NifResult<Term<'a>> {
    let mut cursor_registry = utils::safe_lock(&CURSOR_REGISTRY, "fetch_cursor cursor_registry")?;

    let cursor = cursor_registry
        .get_mut(cursor_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Cursor not found")))?;

    // Verify cursor belongs to this connection
    decode::verify_cursor_ownership(cursor, conn_id)?;

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

    let elixir_rows: Result<Vec<Term>, rustler::Error> = fetched_rows
        .iter()
        .map(|row| {
            let row_terms: Result<Vec<Term>, rustler::Error> = row
                .iter()
                .map(|val| match val {
                    Value::Text(s) => Ok(s.encode(env)),
                    Value::Integer(i) => Ok(i.encode(env)),
                    Value::Real(f) => Ok(f.encode(env)),
                    Value::Blob(b) => OwnedBinary::new(b.len())
                        .ok_or_else(|| {
                            rustler::Error::Term(Box::new(
                                "Failed to allocate binary for blob data",
                            ))
                        })
                        .map(|mut owned| {
                            owned.as_mut_slice().copy_from_slice(b);
                            Binary::from_owned(owned, env).encode(env)
                        }),
                    Value::Null => Ok(rustler::types::atom::nil().encode(env)),
                })
                .collect();
            row_terms.map(|terms| terms.encode(env))
        })
        .collect();

    let elixir_rows = elixir_rows?;
    let result = (elixir_columns, elixir_rows, fetch_count);
    Ok(result.encode(env))
}
