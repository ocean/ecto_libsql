//! Tests for constants.rs - Registry management and global state
//!
//! These tests verify that the global registries (for connections, transactions,
//! statements, and cursors) are properly initialized and accessible.

// Allow unwrap() in tests for cleaner test code - see CLAUDE.md "Test Code Exception"
#![allow(clippy::unwrap_used)]

use crate::constants::{CONNECTION_REGISTRY, CURSOR_REGISTRY, STMT_REGISTRY, TXN_REGISTRY};
use uuid::Uuid;

#[test]
fn test_uuid_generation() {
    let uuid1 = Uuid::new_v4().to_string();
    let uuid2 = Uuid::new_v4().to_string();

    assert_ne!(uuid1, uuid2, "UUIDs should be unique");
    assert_eq!(uuid1.len(), 36, "UUID should be 36 characters long");
}

#[test]
fn test_registry_initialization() {
    // Just verify registries can be accessed
    let conn_registry = CONNECTION_REGISTRY.lock();
    assert!(
        conn_registry.is_ok(),
        "Connection registry should be accessible"
    );

    let txn_registry = TXN_REGISTRY.lock();
    assert!(
        txn_registry.is_ok(),
        "Transaction registry should be accessible"
    );

    let stmt_registry = STMT_REGISTRY.lock();
    assert!(
        stmt_registry.is_ok(),
        "Statement registry should be accessible"
    );

    let cursor_registry = CURSOR_REGISTRY.lock();
    assert!(
        cursor_registry.is_ok(),
        "Cursor registry should be accessible"
    );
}
