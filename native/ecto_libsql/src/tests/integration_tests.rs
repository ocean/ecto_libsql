//! Integration tests with a real SQLite database
//!
//! These tests require libsql to be working and will create temporary databases.
//! They verify that the actual database operations work correctly with parameter
//! binding, transactions, and various data types.

// Allow unwrap() in tests for cleaner test code - see CLAUDE.md "Test Code Exception"
#![allow(clippy::unwrap_used)]

use libsql::{Builder, Value};
use std::fs;
use uuid::Uuid;

fn setup_test_db() -> String {
    format!("z_ecto_libsql_test-{}.db", Uuid::new_v4())
}

fn cleanup_test_db(db_path: &str) {
    let _ = fs::remove_file(db_path);
}

#[tokio::test]
async fn test_create_local_database() {
    let db_path = setup_test_db();

    let result = Builder::new_local(&db_path).build().await;
    assert!(result.is_ok(), "Failed to create local database");

    let db = result.unwrap();
    let conn = db.connect().unwrap();

    // Test basic query
    let result = conn
        .execute("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT)", ())
        .await;
    assert!(result.is_ok(), "Failed to create table");

    cleanup_test_db(&db_path);
}

#[tokio::test]
async fn test_parameter_binding_with_integers() {
    let db_path = setup_test_db();
    let db = Builder::new_local(&db_path).build().await.unwrap();
    let conn = db.connect().unwrap();

    conn.execute("CREATE TABLE users (id INTEGER, age INTEGER)", ())
        .await
        .unwrap();

    // Test integer parameter binding
    let result = conn
        .execute(
            "INSERT INTO users (id, age) VALUES (?1, ?2)",
            vec![Value::Integer(1), Value::Integer(30)],
        )
        .await;

    assert!(result.is_ok(), "Failed to insert with integer params");

    // Verify the data
    let mut rows = conn
        .query(
            "SELECT id, age FROM users WHERE id = ?1",
            vec![Value::Integer(1)],
        )
        .await
        .unwrap();

    let row = rows.next().await.unwrap().unwrap();
    assert_eq!(row.get::<i64>(0).unwrap(), 1);
    assert_eq!(row.get::<i64>(1).unwrap(), 30);

    cleanup_test_db(&db_path);
}

#[tokio::test]
async fn test_parameter_binding_with_floats() {
    let db_path = setup_test_db();
    let db = Builder::new_local(&db_path).build().await.unwrap();
    let conn = db.connect().unwrap();

    conn.execute("CREATE TABLE products (id INTEGER, price REAL)", ())
        .await
        .unwrap();

    // Test float parameter binding
    let result = conn
        .execute(
            "INSERT INTO products (id, price) VALUES (?1, ?2)",
            vec![Value::Integer(1), Value::Real(19.99)],
        )
        .await;

    assert!(result.is_ok(), "Failed to insert with float params");

    // Verify the data
    let mut rows = conn
        .query(
            "SELECT id, price FROM products WHERE id = ?1",
            vec![Value::Integer(1)],
        )
        .await
        .unwrap();

    let row = rows.next().await.unwrap().unwrap();
    assert_eq!(row.get::<i64>(0).unwrap(), 1);
    let price = row.get::<f64>(1).unwrap();
    assert!(
        (price - 19.99).abs() < 0.01,
        "Price should be approximately 19.99"
    );

    cleanup_test_db(&db_path);
}

#[tokio::test]
async fn test_parameter_binding_with_text() {
    let db_path = setup_test_db();
    let db = Builder::new_local(&db_path).build().await.unwrap();
    let conn = db.connect().unwrap();

    conn.execute("CREATE TABLE users (id INTEGER, name TEXT)", ())
        .await
        .unwrap();

    // Test text parameter binding
    let result = conn
        .execute(
            "INSERT INTO users (id, name) VALUES (?1, ?2)",
            vec![Value::Integer(1), Value::Text("Alice".to_string())],
        )
        .await;

    assert!(result.is_ok(), "Failed to insert with text params");

    // Verify the data
    let mut rows = conn
        .query(
            "SELECT name FROM users WHERE id = ?1",
            vec![Value::Integer(1)],
        )
        .await
        .unwrap();

    let row = rows.next().await.unwrap().unwrap();
    assert_eq!(row.get::<String>(0).unwrap(), "Alice");

    cleanup_test_db(&db_path);
}

#[tokio::test]
async fn test_transaction_commit() {
    let db_path = setup_test_db();
    let db = Builder::new_local(&db_path).build().await.unwrap();
    let conn = db.connect().unwrap();

    conn.execute("CREATE TABLE users (id INTEGER, name TEXT)", ())
        .await
        .unwrap();

    // Test transaction
    let tx = conn.transaction().await.unwrap();
    tx.execute(
        "INSERT INTO users (id, name) VALUES (?1, ?2)",
        vec![Value::Integer(1), Value::Text("Alice".to_string())],
    )
    .await
    .unwrap();
    tx.commit().await.unwrap();

    // Verify data was committed
    let mut rows = conn.query("SELECT COUNT(*) FROM users", ()).await.unwrap();
    let row = rows.next().await.unwrap().unwrap();
    assert_eq!(row.get::<i64>(0).unwrap(), 1);

    cleanup_test_db(&db_path);
}

#[tokio::test]
async fn test_transaction_rollback() {
    let db_path = setup_test_db();
    let db = Builder::new_local(&db_path).build().await.unwrap();
    let conn = db.connect().unwrap();

    conn.execute("CREATE TABLE users (id INTEGER, name TEXT)", ())
        .await
        .unwrap();

    // Test transaction rollback
    let tx = conn.transaction().await.unwrap();
    tx.execute(
        "INSERT INTO users (id, name) VALUES (?1, ?2)",
        vec![Value::Integer(1), Value::Text("Alice".to_string())],
    )
    .await
    .unwrap();
    tx.rollback().await.unwrap();

    // Verify data was NOT committed
    let mut rows = conn.query("SELECT COUNT(*) FROM users", ()).await.unwrap();
    let row = rows.next().await.unwrap().unwrap();
    assert_eq!(row.get::<i64>(0).unwrap(), 0);

    cleanup_test_db(&db_path);
}

#[tokio::test]
async fn test_prepared_statement() {
    let db_path = setup_test_db();
    let db = Builder::new_local(&db_path).build().await.unwrap();
    let conn = db.connect().unwrap();

    conn.execute("CREATE TABLE users (id INTEGER, name TEXT)", ())
        .await
        .unwrap();

    // Insert test data
    conn.execute(
        "INSERT INTO users (id, name) VALUES (?1, ?2)",
        vec![Value::Integer(1), Value::Text("Alice".to_string())],
    )
    .await
    .unwrap();
    conn.execute(
        "INSERT INTO users (id, name) VALUES (?1, ?2)",
        vec![Value::Integer(2), Value::Text("Bob".to_string())],
    )
    .await
    .unwrap();

    // Test prepared statement with first parameter
    let stmt1 = conn
        .prepare("SELECT name FROM users WHERE id = ?1")
        .await
        .unwrap();
    let mut result_rows_1 = stmt1.query(vec![Value::Integer(1)]).await.unwrap();
    let first_row = result_rows_1.next().await.unwrap().unwrap();
    assert_eq!(first_row.get::<String>(0).unwrap(), "Alice");

    // Test prepared statement with second parameter (prepare again, mimicking NIF behavior)
    let stmt2 = conn
        .prepare("SELECT name FROM users WHERE id = ?1")
        .await
        .unwrap();
    let mut result_rows_2 = stmt2.query(vec![Value::Integer(2)]).await.unwrap();
    let second_row = result_rows_2.next().await.unwrap().unwrap();
    assert_eq!(second_row.get::<String>(0).unwrap(), "Bob");

    cleanup_test_db(&db_path);
}

#[tokio::test]
async fn test_blob_storage() {
    let db_path = setup_test_db();
    let db = Builder::new_local(&db_path).build().await.unwrap();
    let conn = db.connect().unwrap();

    conn.execute("CREATE TABLE files (id INTEGER, data BLOB)", ())
        .await
        .unwrap();

    let test_data = vec![0u8, 1, 2, 3, 4, 5, 255];
    conn.execute(
        "INSERT INTO files (id, data) VALUES (?1, ?2)",
        vec![Value::Integer(1), Value::Blob(test_data.clone())],
    )
    .await
    .unwrap();

    // Verify blob data
    let mut rows = conn
        .query(
            "SELECT data FROM files WHERE id = ?1",
            vec![Value::Integer(1)],
        )
        .await
        .unwrap();

    let row = rows.next().await.unwrap().unwrap();
    let retrieved_data = row.get::<Vec<u8>>(0).unwrap();
    assert_eq!(retrieved_data, test_data);

    cleanup_test_db(&db_path);
}

#[tokio::test]
async fn test_null_values() {
    let db_path = setup_test_db();
    let db = Builder::new_local(&db_path).build().await.unwrap();
    let conn = db.connect().unwrap();

    conn.execute("CREATE TABLE users (id INTEGER, email TEXT)", ())
        .await
        .unwrap();

    conn.execute(
        "INSERT INTO users (id, email) VALUES (?1, ?2)",
        vec![Value::Integer(1), Value::Null],
    )
    .await
    .unwrap();

    // Verify null handling
    let mut rows = conn
        .query(
            "SELECT email FROM users WHERE id = ?1",
            vec![Value::Integer(1)],
        )
        .await
        .unwrap();

    let row = rows.next().await.unwrap().unwrap();
    let email_value = row.get_value(0).unwrap();
    assert!(matches!(email_value, Value::Null));

    cleanup_test_db(&db_path);
}
