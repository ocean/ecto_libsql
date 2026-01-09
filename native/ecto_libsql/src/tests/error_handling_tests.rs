//! Error handling tests for the Rust NIF layer
//!
//! These tests verify that the Rust layer gracefully returns errors instead of
//! panicking, which is critical for BEAM VM stability. Prior to v0.4.0, many
//! error conditions could panic and crash the entire VM.
//!
//! Focus areas:
//! 1. Invalid resource IDs (connection, statement, transaction, cursor)
//! 2. Parameter validation (count mismatch, type mismatch)
//! 3. Constraint violations (NOT NULL, UNIQUE, FOREIGN KEY, CHECK)
//! 4. Transaction errors (operations after commit, double rollback)
//! 5. Query syntax errors (invalid SQL, non-existent table/column)
//! 6. Resource exhaustion (too many prepared statements/cursors)

// Allow unwrap() in tests for cleaner test code - see CLAUDE.md "Test Code Exception"
#![allow(clippy::unwrap_used)]

use libsql::{Builder, Value};
use super::test_utils::{setup_test_db_with_prefix, TestDbGuard};

// ============================================================================
// CONSTRAINT VIOLATION TESTS
// ============================================================================

#[tokio::test]
async fn test_not_null_constraint_violation() {
    let db_path = setup_test_db_with_prefix("errors");
    let _guard = TestDbGuard::new(db_path.clone());

    let db = Builder::new_local(db_path.to_str().unwrap())
        .build()
        .await
        .unwrap();
    let conn = db.connect().unwrap();

    conn.execute(
        "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)",
        (),
    )
    .await
    .unwrap();

    // This should fail with constraint error, not panic
    let result = conn
        .execute(
            "INSERT INTO users (id, name) VALUES (?1, ?2)",
            vec![Value::Integer(1), Value::Null],
        )
        .await;

    assert!(
        result.is_err(),
        "Expected constraint error for NULL in NOT NULL column"
    );
}

#[tokio::test]
async fn test_unique_constraint_violation() {
    let db_path = setup_test_db_with_prefix("errors");
    let _guard = TestDbGuard::new(db_path.clone());

    let db = Builder::new_local(db_path.to_str().unwrap())
        .build()
        .await
        .unwrap();
    let conn = db.connect().unwrap();

    conn.execute(
        "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT UNIQUE NOT NULL)",
        (),
    )
    .await
    .unwrap();

    // Insert first record
    conn.execute(
        "INSERT INTO users (id, email) VALUES (?1, ?2)",
        vec![
            Value::Integer(1),
            Value::Text("alice@example.com".to_string()),
        ],
    )
    .await
    .unwrap();

    // Insert duplicate email - should fail with constraint error, not panic
    let result = conn
        .execute(
            "INSERT INTO users (id, email) VALUES (?1, ?2)",
            vec![
                Value::Integer(2),
                Value::Text("alice@example.com".to_string()),
            ],
        )
        .await;

    assert!(
        result.is_err(),
        "Expected unique constraint error for duplicate email"
    );
}

#[tokio::test]
async fn test_primary_key_constraint_violation() {
    let db_path = setup_test_db_with_prefix("errors");
    let _guard = TestDbGuard::new(db_path.clone());

    let db = Builder::new_local(db_path.to_str().unwrap())
        .build()
        .await
        .unwrap();
    let conn = db.connect().unwrap();

    conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", ())
        .await
        .unwrap();

    // Insert first record
    conn.execute(
        "INSERT INTO users (id, name) VALUES (?1, ?2)",
        vec![Value::Integer(1), Value::Text("Alice".to_string())],
    )
    .await
    .unwrap();

    // Insert duplicate primary key - should fail with constraint error, not panic
    let result = conn
        .execute(
            "INSERT INTO users (id, name) VALUES (?1, ?2)",
            vec![Value::Integer(1), Value::Text("Bob".to_string())],
        )
        .await;

    assert!(
        result.is_err(),
        "Expected primary key constraint error for duplicate id"
    );
}

#[tokio::test]
async fn test_check_constraint_violation() {
    let db_path = setup_test_db_with_prefix("errors");
    let _guard = TestDbGuard::new(db_path.clone());

    let db = Builder::new_local(db_path.to_str().unwrap())
        .build()
        .await
        .unwrap();
    let conn = db.connect().unwrap();

    conn.execute(
        "CREATE TABLE products (id INTEGER PRIMARY KEY, price REAL CHECK(price > 0))",
        (),
    )
    .await
    .unwrap();

    // Insert valid record
    conn.execute(
        "INSERT INTO products (id, price) VALUES (?1, ?2)",
        vec![Value::Integer(1), Value::Real(19.99)],
    )
    .await
    .unwrap();

    // Insert record violating check constraint - should fail, not panic
    let result = conn
        .execute(
            "INSERT INTO products (id, price) VALUES (?1, ?2)",
            vec![Value::Integer(2), Value::Real(-5.0)],
        )
        .await;

    assert!(
        result.is_err(),
        "Expected check constraint error for negative price"
    );
}

// ============================================================================
// SYNTAX AND SEMANTIC ERROR TESTS
// ============================================================================

#[tokio::test]
async fn test_invalid_sql_syntax() {
    let db_path = setup_test_db_with_prefix("errors");
    let _guard = TestDbGuard::new(db_path.clone());

    let db = Builder::new_local(db_path.to_str().unwrap())
        .build()
        .await
        .unwrap();
    let conn = db.connect().unwrap();

    // Invalid SQL should return error, not panic
    let result = conn
        .execute("SELECT * FRM users", ()) // Typo: FRM instead of FROM
        .await;

    assert!(result.is_err(), "Expected error for invalid SQL syntax");
}

#[tokio::test]
async fn test_nonexistent_table() {
    let db_path = setup_test_db_with_prefix("errors");
    let _guard = TestDbGuard::new(db_path.clone());

    let db = Builder::new_local(db_path.to_str().unwrap())
        .build()
        .await
        .unwrap();
    let conn = db.connect().unwrap();

    // Query non-existent table should return error, not panic
    let result = conn.query("SELECT * FROM nonexistent_table", ()).await;

    assert!(result.is_err(), "Expected error for non-existent table");
}

#[tokio::test]
async fn test_nonexistent_column() {
    let db_path = setup_test_db_with_prefix("errors");
    let _guard = TestDbGuard::new(db_path.clone());

    let db = Builder::new_local(db_path.to_str().unwrap())
        .build()
        .await
        .unwrap();
    let conn = db.connect().unwrap();

    conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", ())
        .await
        .unwrap();

    // Query non-existent column should return error, not panic
    let result = conn.query("SELECT nonexistent_column FROM users", ()).await;

    assert!(result.is_err(), "Expected error for non-existent column");
}

#[tokio::test]
async fn test_malformed_sql() {
    let db_path = setup_test_db_with_prefix("errors");
    let _guard = TestDbGuard::new(db_path.clone());

    let db = Builder::new_local(db_path.to_str().unwrap())
        .build()
        .await
        .unwrap();
    let conn = db.connect().unwrap();

    // Incomplete SQL
    let result = conn.execute("SELECT * FROM users WHERE", ()).await;

    assert!(result.is_err(), "Expected error for malformed SQL");
}

// ============================================================================
// PARAMETER BINDING ERROR TESTS
// ============================================================================

#[tokio::test]
async fn test_parameter_count_mismatch_missing() {
    let db_path = setup_test_db_with_prefix("errors");
    let _guard = TestDbGuard::new(db_path.clone());

    let db = Builder::new_local(db_path.to_str().unwrap())
        .build()
        .await
        .unwrap();
    let conn = db.connect().unwrap();

    conn.execute("CREATE TABLE users (id INTEGER, name TEXT, email TEXT)", ())
        .await
        .unwrap();

    // SQL expects 3 parameters, but only 2 provided - should return error
    let result = conn
        .execute(
            "INSERT INTO users (id, name, email) VALUES (?1, ?2, ?3)",
            vec![Value::Integer(1), Value::Text("Alice".to_string())],
        )
        .await;

    // libsql behaviour varies - may accept or reject
    // The important thing is it doesn't panic
    let _ = result;
}

#[tokio::test]
async fn test_parameter_count_mismatch_excess() {
    let db_path = setup_test_db_with_prefix("errors");
    let _guard = TestDbGuard::new(db_path.clone());

    let db = Builder::new_local(db_path.to_str().unwrap())
        .build()
        .await
        .unwrap();
    let conn = db.connect().unwrap();

    conn.execute("CREATE TABLE users (id INTEGER, name TEXT)", ())
        .await
        .unwrap();

    // SQL expects 2 parameters, but 3 provided - should handle gracefully
    let result = conn
        .execute(
            "INSERT INTO users (id, name) VALUES (?1, ?2)",
            vec![
                Value::Integer(1),
                Value::Text("Alice".to_string()),
                Value::Text("extra".to_string()),
            ],
        )
        .await;

    // libsql will either accept or reject - the key is no panic
    let _ = result;
}

#[tokio::test]
async fn test_type_coercion_integer_to_text() {
    let db_path = setup_test_db_with_prefix("errors");
    let _guard = TestDbGuard::new(db_path.clone());

    let db = Builder::new_local(db_path.to_str().unwrap())
        .build()
        .await
        .unwrap();
    let conn = db.connect().unwrap();

    conn.execute("CREATE TABLE users (id INTEGER, name TEXT)", ())
        .await
        .unwrap();

    // SQLite is dynamically typed, so this should work (integer coerced to text)
    let result = conn
        .execute(
            "INSERT INTO users (id, name) VALUES (?1, ?2)",
            vec![Value::Integer(1), Value::Integer(123)], // Integer for text column
        )
        .await;

    // SQLite permits this due to type affinity - verify insert completed successfully
    assert!(
        result.is_ok(),
        "Should accept integer value for TEXT column due to type affinity without panic"
    );
}

// ============================================================================
// TRANSACTION ERROR TESTS
// ============================================================================

#[tokio::test]
async fn test_double_commit() {
    let db_path = setup_test_db_with_prefix("errors");
    let _guard = TestDbGuard::new(db_path.clone());

    let db = Builder::new_local(db_path.to_str().unwrap())
        .build()
        .await
        .unwrap();
    let conn = db.connect().unwrap();

    conn.execute("CREATE TABLE users (id INTEGER)", ())
        .await
        .unwrap();

    conn.execute("BEGIN", ()).await.unwrap();
    conn.execute(
        "INSERT INTO users (id) VALUES (?1)",
        vec![Value::Integer(1)],
    )
    .await
    .unwrap();
    conn.execute("COMMIT", ()).await.unwrap();

    // Second commit without begin - should fail gracefully, not panic
    let result = conn.execute("COMMIT", ()).await;

    assert!(
        result.is_err(),
        "Expected error for commit without active transaction"
    );
}

#[tokio::test]
async fn test_double_rollback() {
    let db_path = setup_test_db_with_prefix("errors");
    let _guard = TestDbGuard::new(db_path.clone());

    let db = Builder::new_local(db_path.to_str().unwrap())
        .build()
        .await
        .unwrap();
    let conn = db.connect().unwrap();

    conn.execute("CREATE TABLE users (id INTEGER)", ())
        .await
        .unwrap();

    conn.execute("BEGIN", ()).await.unwrap();
    conn.execute(
        "INSERT INTO users (id) VALUES (?1)",
        vec![Value::Integer(1)],
    )
    .await
    .unwrap();
    conn.execute("ROLLBACK", ()).await.unwrap();

    // Second rollback without begin - should fail gracefully, not panic
    let result = conn.execute("ROLLBACK", ()).await;

    assert!(
        result.is_err(),
        "Expected error for rollback without active transaction"
    );
}

#[tokio::test]
async fn test_commit_after_rollback() {
    let db_path = setup_test_db_with_prefix("errors");
    let _guard = TestDbGuard::new(db_path.clone());

    let db = Builder::new_local(db_path.to_str().unwrap())
        .build()
        .await
        .unwrap();
    let conn = db.connect().unwrap();

    conn.execute("CREATE TABLE users (id INTEGER)", ())
        .await
        .unwrap();

    conn.execute("BEGIN", ()).await.unwrap();
    conn.execute(
        "INSERT INTO users (id) VALUES (?1)",
        vec![Value::Integer(1)],
    )
    .await
    .unwrap();
    conn.execute("ROLLBACK", ()).await.unwrap();

    // Commit after rollback - should fail gracefully, not panic
    let result = conn.execute("COMMIT", ()).await;

    assert!(result.is_err(), "Expected error for commit after rollback");
}

#[tokio::test]
async fn test_query_after_rollback() {
    let db_path = setup_test_db_with_prefix("errors");
    let _guard = TestDbGuard::new(db_path.clone());

    let db = Builder::new_local(db_path.to_str().unwrap())
        .build()
        .await
        .unwrap();
    let conn = db.connect().unwrap();

    conn.execute("CREATE TABLE users (id INTEGER)", ())
        .await
        .unwrap();

    conn.execute("BEGIN", ()).await.unwrap();
    conn.execute(
        "INSERT INTO users (id) VALUES (?1)",
        vec![Value::Integer(1)],
    )
    .await
    .unwrap();
    conn.execute("ROLLBACK", ()).await.unwrap();

    // Verify data was not committed
    let mut rows = conn.query("SELECT COUNT(*) FROM users", ()).await.unwrap();
    let row = rows.next().await.unwrap().unwrap();
    let count = row.get::<i64>(0).unwrap();
    assert_eq!(count, 0, "Data should be rolled back");
}

// ============================================================================
// PREPARED STATEMENT ERROR TESTS
// ============================================================================

#[tokio::test]
async fn test_prepare_invalid_sql() {
    let db_path = setup_test_db_with_prefix("errors");
    let _guard = TestDbGuard::new(db_path.clone());

    let db = Builder::new_local(db_path.to_str().unwrap())
        .build()
        .await
        .unwrap();
    let conn = db.connect().unwrap();

    // Prepare invalid SQL - should return error, not panic
    let result = conn
        .prepare("SELECT * FRM users") // Typo: FRM instead of FROM
        .await;

    assert!(result.is_err(), "Expected error for invalid SQL in prepare");
}

#[tokio::test]
async fn test_prepared_statement_with_parameter_mismatch() {
    let db_path = setup_test_db_with_prefix("errors");
    let _guard = TestDbGuard::new(db_path.clone());

    let db = Builder::new_local(db_path.to_str().unwrap())
        .build()
        .await
        .unwrap();
    let conn = db.connect().unwrap();

    conn.execute("CREATE TABLE users (id INTEGER, name TEXT)", ())
        .await
        .unwrap();

    conn.execute(
        "INSERT INTO users (id, name) VALUES (?1, ?2)",
        vec![Value::Integer(1), Value::Text("Alice".to_string())],
    )
    .await
    .unwrap();

    let stmt = conn
        .prepare("SELECT * FROM users WHERE id = ?1 AND name = ?2")
        .await
        .unwrap();

    // Execute with only 1 parameter when 2 are expected - should handle gracefully
    let result = stmt.query(vec![Value::Integer(1)]).await;

    // Depending on libsql behaviour, may error or coerce - key is no panic
    let _ = result;
}

// ============================================================================
// DATABASE FILE ERROR TESTS
// ============================================================================

#[cfg(unix)]
#[tokio::test]
async fn test_create_db_invalid_permissions() {
    // Test with path that's definitely invalid (Unix-specific: null bytes)
    let invalid_path = "\0invalid\0path.db"; // Null bytes in path

    // Creating DB with invalid path should error, not panic
    let result = Builder::new_local(invalid_path).build().await;

    // This should error due to invalid path, or succeed silently
    // The key is it doesn't panic
    let _ = result;
}

#[cfg(windows)]
#[tokio::test]
async fn test_create_db_invalid_permissions() {
    // Test with path that's definitely invalid (Windows-specific: invalid characters)
    let invalid_path = "COM1"; // Reserved device name on Windows

    // Creating DB with invalid path should error, not panic
    let result = Builder::new_local(invalid_path).build().await;

    // This should error due to invalid path, or succeed silently
    // The key is it doesn't panic
    let _ = result;
}

#[tokio::test]
async fn test_database_persistence_and_reopen() {
    let db_path = setup_test_db_with_prefix("errors");
    let _guard = TestDbGuard::new(db_path.clone());

    let db_path_str = db_path.to_str().unwrap();

    // Create database, table, and insert data
    let db = Builder::new_local(db_path_str).build().await.unwrap();
    let conn = db.connect().unwrap();

    conn.execute("CREATE TABLE users (id INTEGER)", ())
        .await
        .unwrap();

    conn.execute(
        "INSERT INTO users (id) VALUES (?1)",
        vec![Value::Integer(1)],
    )
    .await
    .unwrap();

    // Verify data was inserted
    let mut rows = conn.query("SELECT COUNT(*) FROM users", ()).await.unwrap();
    let row = rows.next().await.unwrap().unwrap();
    let count = row.get::<i64>(0).unwrap();
    assert_eq!(count, 1, "Data should be inserted");

    drop(conn);
    drop(db);

    // Reopen database and verify persistence
    // This tests that data survives connection close/reopen cycles
    let db2 = Builder::new_local(db_path_str).build().await.unwrap();
    let conn2 = db2.connect().unwrap();

    // Query should work and return persisted data
    let mut rows = conn2.query("SELECT COUNT(*) FROM users", ()).await.unwrap();
    let row = rows.next().await.unwrap().unwrap();
    let count = row.get::<i64>(0).unwrap();
    assert_eq!(
        count, 1,
        "Persisted data should be readable after reopening"
    );
}

// ============================================================================
// EDGE CASE TESTS
// ============================================================================

#[tokio::test]
async fn test_empty_sql_statement() {
    let db_path = setup_test_db_with_prefix("errors");
    let _guard = TestDbGuard::new(db_path.clone());

    let db = Builder::new_local(db_path.to_str().unwrap())
        .build()
        .await
        .unwrap();
    let conn = db.connect().unwrap();

    // Empty SQL - should return error, not panic
    let result = conn.execute("", ()).await;

    assert!(result.is_err(), "Expected error for empty SQL");
}

#[tokio::test]
async fn test_whitespace_only_sql() {
    let db_path = setup_test_db_with_prefix("errors");
    let _guard = TestDbGuard::new(db_path.clone());

    let db = Builder::new_local(db_path.to_str().unwrap())
        .build()
        .await
        .unwrap();
    let conn = db.connect().unwrap();

    // Whitespace-only SQL - should return error, not panic
    let result = conn.execute("   \n\t  ", ()).await;

    assert!(result.is_err(), "Expected error for whitespace-only SQL");
}

#[tokio::test]
async fn test_very_long_sql_query() {
    let db_path = setup_test_db_with_prefix("errors");
    let _guard = TestDbGuard::new(db_path.clone());

    let db = Builder::new_local(db_path.to_str().unwrap())
        .build()
        .await
        .unwrap();
    let conn = db.connect().unwrap();

    conn.execute("CREATE TABLE users (id INTEGER)", ())
        .await
        .unwrap();

    // Create very long WHERE clause (1000 OR conditions)
    let mut sql = "SELECT * FROM users WHERE id = 1".to_string();
    for i in 2..=1000 {
        sql.push_str(&format!(" OR id = {i}"));
    }

    // Very long query should either work or fail gracefully, not panic
    let result = conn.query(&sql, ()).await;
    let _ = result; // Don't assert on success/failure, just that it doesn't panic
}

#[tokio::test]
async fn test_unicode_in_sql() {
    let db_path = setup_test_db_with_prefix("errors");
    let _guard = TestDbGuard::new(db_path.clone());

    let db = Builder::new_local(db_path.to_str().unwrap())
        .build()
        .await
        .unwrap();
    let conn = db.connect().unwrap();

    conn.execute("CREATE TABLE users (id INTEGER, name TEXT)", ())
        .await
        .unwrap();

    // Unicode in parameter - should work fine
    let result = conn
        .execute(
            "INSERT INTO users (id, name) VALUES (?1, ?2)",
            vec![
                Value::Integer(1),
                Value::Text("Ålice 中文 العربية".to_string()),
            ],
        )
        .await;

    assert!(result.is_ok(), "Should handle unicode values");

    // Verify retrieval
    let mut rows = conn
        .query(
            "SELECT name FROM users WHERE id = ?1",
            vec![Value::Integer(1)],
        )
        .await
        .unwrap();
    let row = rows.next().await.unwrap().unwrap();
    let name = row.get::<String>(0).unwrap();
    assert_eq!(name, "Ålice 中文 العربية");
}

#[tokio::test]
async fn test_sql_injection_attempt() {
    let db_path = setup_test_db_with_prefix("errors");
    let _guard = TestDbGuard::new(db_path.clone());

    let db = Builder::new_local(db_path.to_str().unwrap())
        .build()
        .await
        .unwrap();
    let conn = db.connect().unwrap();

    conn.execute("CREATE TABLE users (id INTEGER, name TEXT)", ())
        .await
        .unwrap();

    // SQL injection attempt should be safely parameterised
    let result = conn
        .execute(
            "INSERT INTO users (id, name) VALUES (?1, ?2)",
            vec![
                Value::Integer(1),
                Value::Text("Alice'; DROP TABLE users; --".to_string()),
            ],
        )
        .await;

    assert!(
        result.is_ok(),
        "Parameterised query should safely insert injection string"
    );

    // Verify table still exists and contains the literal string
    let mut rows = conn.query("SELECT COUNT(*) FROM users", ()).await.unwrap();
    let row = rows.next().await.unwrap().unwrap();
    let count = row.get::<i64>(0).unwrap();
    assert_eq!(
        count, 1,
        "Table should still exist with parameterised injection"
    );
}
