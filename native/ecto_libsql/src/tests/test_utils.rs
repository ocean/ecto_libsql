//! Shared test utilities for integration and error handling tests
//!
//! This module provides common test infrastructure used across multiple test files
//! to avoid duplication and ensure consistent test behavior.

use std::fs;
use std::path::PathBuf;
use uuid::Uuid;

/// RAII guard that ensures database and associated SQLite files are cleaned up
/// after all database handles (conn, db) are dropped.
///
/// This guard must be declared FIRST in tests so its Drop impl runs LAST,
/// ensuring files are deleted only after the db connection is fully closed.
/// This prevents Windows file-lock issues with .db, .db-wal, .db-shm, and other
/// SQLite auxiliary files. Removes all five file types for parity with Elixir's
/// cleanup_db_files/1 helper:
/// - .db (main database file)
/// - .db-wal (Write-Ahead Log)
/// - .db-shm (Shared Memory)
/// - .db-journal (Journal file)
/// - .db-info (Info file for replication metadata)
pub struct TestDbGuard {
    db_path: PathBuf,
}

impl TestDbGuard {
    /// Create a new test database guard for the given path.
    ///
    /// # Example
    ///
    /// ```ignore
    /// let db_path = setup_test_db();
    /// let _guard = TestDbGuard::new(db_path.clone());
    /// // ... database operations ...
    /// // Guard automatically cleans up when dropped
    /// ```
    pub fn new(db_path: PathBuf) -> Self {
        TestDbGuard { db_path }
    }
}

impl Drop for TestDbGuard {
    fn drop(&mut self) {
        // Remove main database file
        let _ = fs::remove_file(&self.db_path);

        // Remove WAL (Write-Ahead Log) file
        let wal_path = format!("{}-wal", self.db_path.display());
        let _ = fs::remove_file(&wal_path);

        // Remove SHM (Shared Memory) file
        let shm_path = format!("{}-shm", self.db_path.display());
        let _ = fs::remove_file(&shm_path);

        // Remove JOURNAL file (SQLite rollback journal)
        let journal_path = format!("{}-journal", self.db_path.display());
        let _ = fs::remove_file(&journal_path);

        // Remove INFO file (replication metadata for remote replicas)
        let info_path = format!("{}-info", self.db_path.display());
        let _ = fs::remove_file(&info_path);
    }
}

/// Set up a unique test database file in the system temp directory.
///
/// Generates a unique database filename using UUID to ensure test isolation.
///
/// # Returns
///
/// A `PathBuf` pointing to a temporary database file.
///
/// # Example
///
/// ```ignore
/// let db_path = setup_test_db();
/// let _guard = TestDbGuard::new(db_path.clone());
/// let db = Builder::new_local(db_path.to_str().unwrap()).build().await.unwrap();
/// ```
pub fn setup_test_db() -> PathBuf {
    let temp_dir = std::env::temp_dir();
    let db_name = format!("z_ecto_libsql_test-{}.db", Uuid::new_v4());
    temp_dir.join(db_name)
}

/// Set up a test database with a specific name prefix.
///
/// Useful when you want to ensure a specific database name pattern for debugging.
///
/// # Arguments
///
/// * `prefix` - A string prefix for the database name (e.g., "errors", "integration")
///
/// # Returns
///
/// A `PathBuf` pointing to a temporary database file with the given prefix.
///
/// # Example
///
/// ```ignore
/// let db_path = setup_test_db_with_prefix("errors");
/// // Results in: /tmp/z_ecto_libsql_test-errors-<uuid>.db
/// ```
pub fn setup_test_db_with_prefix(prefix: &str) -> PathBuf {
    let temp_dir = std::env::temp_dir();
    let db_name = format!("z_ecto_libsql_test-{}-{}.db", prefix, Uuid::new_v4());
    temp_dir.join(db_name)
}
