/// Decoding and type conversion utilities
///
/// This module provides functions to convert Elixir atoms and values into
/// Rust types, and to validate resource ownership.
use libsql::TransactionBehavior;
use rustler::Atom;

use crate::constants::*;
use crate::models::{CursorData, Mode};

/// Decode an Elixir atom to a Mode enum
///
/// Converts atoms like `:local`, `:remote`, `:remote_replica` to their Rust equivalents.
pub fn decode_mode(atom: Atom) -> Option<Mode> {
    if atom == remote_replica() {
        Some(Mode::RemoteReplica)
    } else if atom == remote() {
        Some(Mode::Remote)
    } else if atom == local() {
        Some(Mode::Local)
    } else {
        None
    }
}

/// Decode an Elixir atom to a TransactionBehavior
///
/// Converts atoms like `:deferred`, `:immediate`, `:exclusive`, `:read_only`
/// to their LibSQL equivalents.
pub fn decode_transaction_behavior(atom: Atom) -> Option<TransactionBehavior> {
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

/// Verify that a prepared statement belongs to the specified connection
///
/// Returns error if the statement's connection ID doesn't match.
pub fn verify_statement_ownership(stmt_conn_id: &str, conn_id: &str) -> Result<(), rustler::Error> {
    if stmt_conn_id != conn_id {
        return Err(rustler::Error::Term(Box::new(
            "Statement does not belong to connection",
        )));
    }
    Ok(())
}

/// Verify that a cursor belongs to the specified connection
///
/// Returns error if the cursor's connection ID doesn't match.
pub fn verify_cursor_ownership(cursor: &CursorData, conn_id: &str) -> Result<(), rustler::Error> {
    if cursor.conn_id != conn_id {
        return Err(rustler::Error::Term(Box::new(
            "Cursor does not belong to connection",
        )));
    }
    Ok(())
}

/// Validate that a savepoint name is a valid SQL identifier
///
/// Savepoint names must be:
/// - Non-empty
/// - ASCII alphanumeric or underscore
/// - Not start with a digit
pub fn validate_savepoint_name(name: &str) -> Result<(), rustler::Error> {
    if name.is_empty()
        || !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
        || name.chars().next().is_none_or(|c| c.is_ascii_digit())
    {
        return Err(rustler::Error::Term(Box::new(
            "Invalid savepoint name: must be a valid SQL identifier",
        )));
    }
    Ok(())
}
