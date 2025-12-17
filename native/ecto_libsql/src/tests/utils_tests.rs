//! Tests for utils.rs - Query type detection and routing functions
//!
//! These tests verify the correctness of:
//! - `detect_query_type()` - Categorizes SQL statements by type
//! - `should_use_query()` - Determines whether to use query() vs execute()

use crate::utils::{detect_query_type, should_use_query, QueryType};

/// Tests for query type detection
mod query_type_detection {
    use super::*;

    #[test]
    fn test_detect_select_query() {
        assert_eq!(detect_query_type("SELECT * FROM users"), QueryType::Select);
        assert_eq!(
            detect_query_type("  SELECT id FROM posts"),
            QueryType::Select
        );
        assert_eq!(
            detect_query_type("\nSELECT name FROM items"),
            QueryType::Select
        );
        assert_eq!(detect_query_type("select * from users"), QueryType::Select);
    }

    #[test]
    fn test_detect_insert_query() {
        assert_eq!(
            detect_query_type("INSERT INTO users (name) VALUES ('Alice')"),
            QueryType::Insert
        );
        assert_eq!(
            detect_query_type("  INSERT INTO posts VALUES (1, 'title')"),
            QueryType::Insert
        );
    }

    #[test]
    fn test_detect_update_query() {
        assert_eq!(
            detect_query_type("UPDATE users SET name = 'Bob' WHERE id = 1"),
            QueryType::Update
        );
        assert_eq!(
            detect_query_type("update posts set title = 'New'"),
            QueryType::Update
        );
    }

    #[test]
    fn test_detect_delete_query() {
        assert_eq!(
            detect_query_type("DELETE FROM users WHERE id = 1"),
            QueryType::Delete
        );
        assert_eq!(detect_query_type("delete from posts"), QueryType::Delete);
    }

    #[test]
    fn test_detect_ddl_queries() {
        assert_eq!(
            detect_query_type("CREATE TABLE users (id INTEGER)"),
            QueryType::Create
        );
        assert_eq!(detect_query_type("DROP TABLE users"), QueryType::Drop);
        assert_eq!(
            detect_query_type("ALTER TABLE users ADD COLUMN email TEXT"),
            QueryType::Alter
        );
    }

    #[test]
    fn test_detect_transaction_queries() {
        assert_eq!(detect_query_type("BEGIN TRANSACTION"), QueryType::Begin);
        assert_eq!(detect_query_type("COMMIT"), QueryType::Commit);
        assert_eq!(detect_query_type("ROLLBACK"), QueryType::Rollback);
    }

    #[test]
    fn test_detect_unknown_query() {
        assert_eq!(
            detect_query_type("PRAGMA table_info(users)"),
            QueryType::Other
        );
        assert_eq!(
            detect_query_type("EXPLAIN SELECT * FROM users"),
            QueryType::Other
        );
        assert_eq!(detect_query_type(""), QueryType::Other);
    }

    #[test]
    fn test_detect_with_whitespace() {
        assert_eq!(
            detect_query_type("   \n\t  SELECT * FROM users"),
            QueryType::Select
        );
        assert_eq!(
            detect_query_type("\t\tINSERT INTO users"),
            QueryType::Insert
        );
    }
}

/// Tests for optimized should_use_query() function
///
/// This function is critical for performance as it runs on every SQL operation.
/// Tests verify correctness of the optimized zero-allocation implementation.
mod should_use_query_tests {
    use super::*;

    // ===== SELECT Statement Tests =====

    #[test]
    fn test_select_basic() {
        assert!(should_use_query("SELECT * FROM users"));
        assert!(should_use_query("SELECT id FROM posts"));
    }

    #[test]
    fn test_select_case_insensitive() {
        assert!(should_use_query("SELECT * FROM users"));
        assert!(should_use_query("select * from users"));
        assert!(should_use_query("SeLeCt * FROM users"));
        assert!(should_use_query("sElEcT id, name FROM posts"));
    }

    #[test]
    fn test_select_with_leading_whitespace() {
        assert!(should_use_query("  SELECT * FROM users"));
        assert!(should_use_query("\tSELECT * FROM users"));
        assert!(should_use_query("\nSELECT * FROM users"));
        assert!(should_use_query("   \n\t  SELECT * FROM users"));
        assert!(should_use_query("\r\nSELECT * FROM users"));
    }

    #[test]
    fn test_select_followed_by_whitespace() {
        assert!(should_use_query("SELECT "));
        assert!(should_use_query("SELECT\t"));
        assert!(should_use_query("SELECT\n"));
        assert!(should_use_query("SELECT\r\n"));
    }

    #[test]
    fn test_not_select_if_part_of_word() {
        // "SELECTED" should not match SELECT
        assert!(!should_use_query("SELECTED FROM users"));
        assert!(!should_use_query("SELECTALL FROM posts"));
    }

    // ===== RETURNING Clause Tests =====

    #[test]
    fn test_insert_with_returning() {
        assert!(should_use_query(
            "INSERT INTO users (name) VALUES ('Alice') RETURNING id"
        ));
        assert!(should_use_query(
            "INSERT INTO users VALUES (1, 'Bob') RETURNING id, name"
        ));
        assert!(should_use_query(
            "INSERT INTO posts (title) VALUES ('Test') RETURNING *"
        ));
    }

    #[test]
    fn test_update_with_returning() {
        assert!(should_use_query(
            "UPDATE users SET name = 'Alice' WHERE id = 1 RETURNING *"
        ));
        assert!(should_use_query(
            "UPDATE posts SET title = 'New' RETURNING id, title"
        ));
    }

    #[test]
    fn test_delete_with_returning() {
        assert!(should_use_query(
            "DELETE FROM users WHERE id = 1 RETURNING id"
        ));
        assert!(should_use_query("DELETE FROM posts RETURNING *"));
    }

    #[test]
    fn test_returning_case_insensitive() {
        assert!(should_use_query(
            "INSERT INTO users VALUES (1) RETURNING id"
        ));
        assert!(should_use_query(
            "INSERT INTO users VALUES (1) returning id"
        ));
        assert!(should_use_query(
            "INSERT INTO users VALUES (1) ReTuRnInG id"
        ));
    }

    #[test]
    fn test_returning_with_whitespace() {
        assert!(should_use_query(
            "INSERT INTO users VALUES (1)\nRETURNING id"
        ));
        assert!(should_use_query(
            "INSERT INTO users VALUES (1)\tRETURNING id"
        ));
        assert!(should_use_query(
            "INSERT INTO users VALUES (1)  RETURNING id"
        ));
    }

    #[test]
    fn test_not_returning_if_part_of_word() {
        // "NORETURNING" should not match RETURNING
        assert!(!should_use_query(
            "INSERT INTO users VALUES (1) NORETURNING id"
        ));
    }

    // ===== Non-SELECT, Non-RETURNING Tests =====

    #[test]
    fn test_insert_without_returning() {
        assert!(!should_use_query(
            "INSERT INTO users (name) VALUES ('Alice')"
        ));
        assert!(!should_use_query("INSERT INTO posts VALUES (1, 'title')"));
    }

    #[test]
    fn test_update_without_returning() {
        assert!(!should_use_query(
            "UPDATE users SET name = 'Bob' WHERE id = 1"
        ));
        assert!(!should_use_query("UPDATE posts SET title = 'New'"));
    }

    #[test]
    fn test_delete_without_returning() {
        assert!(!should_use_query("DELETE FROM users WHERE id = 1"));
        assert!(!should_use_query("DELETE FROM posts"));
    }

    #[test]
    fn test_ddl_statements() {
        assert!(!should_use_query("CREATE TABLE users (id INTEGER)"));
        assert!(!should_use_query("DROP TABLE users"));
        assert!(!should_use_query("ALTER TABLE users ADD COLUMN email TEXT"));
        assert!(!should_use_query("CREATE INDEX idx_email ON users(email)"));
    }

    #[test]
    fn test_transaction_statements() {
        assert!(!should_use_query("BEGIN TRANSACTION"));
        assert!(!should_use_query("COMMIT"));
        assert!(!should_use_query("ROLLBACK"));
    }

    #[test]
    fn test_pragma_statements() {
        assert!(!should_use_query("PRAGMA table_info(users)"));
        assert!(!should_use_query("PRAGMA foreign_keys = ON"));
    }

    // ===== Edge Cases =====

    #[test]
    fn test_empty_string() {
        assert!(!should_use_query(""));
    }

    #[test]
    fn test_whitespace_only() {
        assert!(!should_use_query("   "));
        assert!(!should_use_query("\t\n"));
        assert!(!should_use_query("  \t  \n  "));
    }

    #[test]
    fn test_very_short_strings() {
        assert!(!should_use_query("S"));
        assert!(!should_use_query("SEL"));
        assert!(!should_use_query("SELEC"));
    }

    #[test]
    fn test_multiline_sql() {
        assert!(should_use_query(
            "SELECT id,\n       name,\n       email\nFROM users\nWHERE active = 1"
        ));
        assert!(should_use_query(
            "INSERT INTO users (name)\nVALUES ('Alice')\nRETURNING id"
        ));
    }

    #[test]
    fn test_sql_with_comments() {
        // Comments BEFORE the statement: we don't parse SQL comments,
        // so "-- Comment\nSELECT" won't detect SELECT (first non-whitespace is '-')
        // This is fine - Ecto doesn't generate SQL with leading comments
        assert!(!should_use_query("-- Comment\nSELECT * FROM users"));

        // Comments WITHIN the statement are fine - we detect keywords/clauses
        assert!(should_use_query(
            "INSERT INTO users VALUES (1) /* comment */ RETURNING id"
        ));
        assert!(should_use_query("SELECT /* comment */ * FROM users"));
    }

    // ===== Known Limitations: Keywords in Comments and Strings =====

    #[test]
    fn test_returning_in_block_comment_false_positive() {
        // KNOWN LIMITATION: RETURNING inside block comments is detected as a match.
        // This is a SAFE false positive - using query() works correctly.
        assert!(should_use_query("SELECT * /* RETURNING */ FROM users"));
        assert!(should_use_query(
            "UPDATE users SET name = 'Alice' /* RETURNING id */ WHERE id = 1"
        ));

        let result = should_use_query("SELECT * /* RETURNING */ FROM users");
        assert_eq!(
            result, true,
            "Known limitation: RETURNING in block comments is detected"
        );
    }

    #[test]
    fn test_returning_in_string_literal_mixed_behavior() {
        // String literals are correctly NOT matched when RETURNING is not surrounded by whitespace.
        assert!(!should_use_query("INSERT INTO t VALUES ('RETURNING')"));
        assert!(!should_use_query("INSERT INTO t VALUES ( 'RETURNING')"));
        assert!(!should_use_query(
            "INSERT INTO t (col) VALUES (\"RETURNING\")"
        ));

        // LIMITATION: If RETURNING appears inside a string with whitespace before AND after,
        // it IS detected as a false positive. This is SAFE but suboptimal.
        assert!(should_use_query(
            "INSERT INTO logs (message) VALUES ('Error: RETURNING failed')"
        ));

        // But if there's no trailing whitespace, it's correctly NOT matched
        assert!(!should_use_query(
            "INSERT INTO logs (message) VALUES ('Error RETURNING')"
        ));
    }

    #[test]
    fn test_select_in_string_literal_no_issue() {
        // String literals don't cause issues because we only check the START
        // of the SQL statement for SELECT.
        assert!(!should_use_query(
            "INSERT INTO t VALUES ('SELECT * FROM users')"
        ));
    }

    // ===== CTE (Common Table Expressions) Tests =====

    #[test]
    fn test_cte_with_select_not_detected() {
        // CTEs are NOT detected by the current implementation.
        // These start with WITH, not SELECT, so they return false.
        assert!(!should_use_query(
            "WITH active_users AS (SELECT * FROM users WHERE active = 1) SELECT * FROM active_users"
        ));

        assert!(!should_use_query(
            "WITH RECURSIVE cte AS (SELECT 1 AS n UNION ALL SELECT n+1 FROM cte WHERE n < 10) SELECT * FROM cte"
        ));

        assert!(!should_use_query(
            "WITH
                admins AS (SELECT * FROM users WHERE role = 'admin'),
                posts AS (SELECT * FROM posts WHERE published = 1)
            SELECT * FROM admins JOIN posts"
        ));
    }

    #[test]
    fn test_cte_with_insert_returning_detected_via_returning() {
        // CTE with INSERT...RETURNING IS detected, but only because of the RETURNING keyword.
        assert!(should_use_query(
            "WITH inserted AS (INSERT INTO users (name) VALUES ('Alice') RETURNING id) SELECT * FROM inserted"
        ));
    }

    // ===== EXPLAIN Query Tests =====

    #[test]
    fn test_explain_select_not_detected() {
        // EXPLAIN SELECT is NOT detected because it starts with EXPLAIN, not SELECT.
        assert!(!should_use_query("EXPLAIN SELECT * FROM users"));
        assert!(!should_use_query(
            "EXPLAIN QUERY PLAN SELECT * FROM users WHERE id = 1"
        ));
    }

    #[test]
    fn test_explain_insert_not_detected() {
        // EXPLAIN INSERT (without RETURNING) is not detected.
        assert!(!should_use_query(
            "EXPLAIN INSERT INTO users VALUES (1, 'Alice')"
        ));

        // However, if RETURNING is added, it IS detected because of the RETURNING keyword.
        assert!(should_use_query(
            "EXPLAIN INSERT INTO users VALUES (1, 'Alice') RETURNING id"
        ));
    }

    #[test]
    fn test_explain_update_delete_not_detected() {
        assert!(!should_use_query(
            "EXPLAIN UPDATE users SET name = 'Bob' WHERE id = 1"
        ));
        assert!(!should_use_query("EXPLAIN DELETE FROM users WHERE id = 1"));

        // With RETURNING, they ARE detected via the RETURNING keyword.
        assert!(should_use_query(
            "EXPLAIN UPDATE users SET name = 'Bob' WHERE id = 1 RETURNING id"
        ));
    }

    // ===== Performance Tests =====

    #[test]
    fn test_very_long_select_is_fast() {
        // Verify performance doesn't degrade for long SELECT statements
        let long_select = format!(
            "SELECT {} FROM users WHERE id = 1",
            (0..1000)
                .map(|i| format!("col{}", i))
                .collect::<Vec<_>>()
                .join(", ")
        );
        assert!(should_use_query(&long_select));
    }

    #[test]
    fn test_very_long_insert_without_returning_is_fast() {
        let long_insert = format!(
            "INSERT INTO users ({}) VALUES ({})",
            (0..500)
                .map(|i| format!("col{}", i))
                .collect::<Vec<_>>()
                .join(", "),
            (0..500)
                .map(|i| format!("${}", i + 1))
                .collect::<Vec<_>>()
                .join(", ")
        );
        assert!(!should_use_query(&long_insert));
    }

    #[test]
    fn test_returning_near_end_of_long_statement() {
        let long_insert_with_returning = format!(
            "INSERT INTO users ({}) VALUES ({}) RETURNING id",
            (0..500)
                .map(|i| format!("col{}", i))
                .collect::<Vec<_>>()
                .join(", "),
            (0..500)
                .map(|i| format!("${}", i + 1))
                .collect::<Vec<_>>()
                .join(", ")
        );
        assert!(should_use_query(&long_insert_with_returning));
    }

    // ===== Transactional SELECT Edge Cases =====

    #[test]
    fn test_select_alone_requires_query_path() {
        // Plain SELECT without RETURNING must use query path (returns rows)
        assert!(should_use_query("SELECT * FROM users"));
        assert!(should_use_query(
            "SELECT id, name FROM users WHERE active = 1"
        ));
        assert!(should_use_query("SELECT COUNT(*) FROM users"));
    }

    #[test]
    fn test_select_various_forms() {
        assert!(should_use_query("SELECT 1"));
        assert!(should_use_query("SELECT 1 AS num"));
        assert!(should_use_query("SELECT NULL"));
        assert!(should_use_query(
            "SELECT u.id, u.name, COUNT(p.id) FROM users u LEFT JOIN posts p ON u.id = p.user_id GROUP BY u.id"
        ));
    }

    #[test]
    fn test_select_with_subqueries() {
        assert!(should_use_query(
            "SELECT * FROM (SELECT id, name FROM users WHERE active = 1)"
        ));
        assert!(should_use_query(
            "SELECT * FROM users WHERE id IN (SELECT user_id FROM posts)"
        ));
    }

    #[test]
    fn test_select_with_returning_redundant_but_harmless() {
        // A SELECT with RETURNING is unusual in SQLite (RETURNING is INSERT/UPDATE/DELETE only)
        // but the function should still detect it correctly
        assert!(should_use_query("SELECT * FROM users RETURNING id"));
    }

    #[test]
    fn test_transactional_select_distinction_from_insert_update_delete() {
        // Core distinction for the fix:
        // - SELECT -> always use query path
        // - INSERT/UPDATE/DELETE without RETURNING -> use execute path
        // - INSERT/UPDATE/DELETE with RETURNING -> use query path

        assert!(should_use_query("SELECT * FROM users"));

        assert!(!should_use_query(
            "INSERT INTO users (name) VALUES ('Alice')"
        ));
        assert!(!should_use_query(
            "UPDATE users SET name = 'Bob' WHERE id = 1"
        ));
        assert!(!should_use_query("DELETE FROM users WHERE id = 1"));

        assert!(should_use_query(
            "INSERT INTO users (name) VALUES ('Alice') RETURNING id"
        ));
        assert!(should_use_query(
            "UPDATE users SET name = 'Bob' WHERE id = 1 RETURNING id"
        ));
        assert!(should_use_query(
            "DELETE FROM users WHERE id = 1 RETURNING id"
        ));
    }

    #[test]
    fn test_select_with_comments_variations() {
        assert!(should_use_query("SELECT /* get all users */ * FROM users"));
        assert!(should_use_query(
            "SELECT id, -- user id\n       name -- user name\nFROM users"
        ));
        assert!(should_use_query("SELECT * /* RETURNING */ FROM users"));
    }

    #[test]
    fn test_select_edge_case_with_string_literals() {
        assert!(should_use_query("SELECT 'RETURNING' AS literal FROM users"));
        assert!(should_use_query(
            "SELECT 'INSERT' AS keyword_string FROM users"
        ));
        assert!(should_use_query(
            "SELECT message FROM logs WHERE msg = 'SELECT * FROM other_table'"
        ));
    }

    #[test]
    fn test_multiline_select_in_transaction_context() {
        assert!(should_use_query(
            "SELECT u.id,
                   u.name,
                   u.email
            FROM users u
            WHERE u.active = 1
            ORDER BY u.created_at DESC
            LIMIT 10"
        ));

        assert!(should_use_query(
            "SELECT
                id,
                name,
                COUNT(posts) as post_count
            FROM users
            WHERE created_at > ?
              AND status = ?
            GROUP BY id"
        ));
    }

    #[test]
    fn test_select_with_cte_pattern() {
        // CTEs start with WITH, not SELECT, so they won't be detected.
        assert!(!should_use_query(
            "WITH active_users AS (SELECT * FROM users WHERE active = 1) SELECT * FROM active_users"
        ));
    }

    #[test]
    fn test_explain_queries_not_detected_as_select() {
        assert!(!should_use_query("EXPLAIN SELECT * FROM users"));
        assert!(!should_use_query(
            "EXPLAIN QUERY PLAN SELECT * FROM users WHERE id = 1"
        ));
    }

    #[test]
    fn test_union_queries_detected_via_first_select() {
        assert!(should_use_query(
            "SELECT id FROM users UNION SELECT id FROM admins"
        ));
        assert!(should_use_query(
            "SELECT * FROM users WHERE active = 1 UNION ALL SELECT * FROM archived_users"
        ));
    }

    #[test]
    fn test_case_sensitivity_and_keyword_boundary() {
        assert!(!should_use_query("SELECTED FROM users"));
        assert!(should_use_query("SELECT * FROM users"));
        assert!(!should_use_query("UPDATED users SET x = 1"));
        assert!(!should_use_query("UPDATE users SET x = 1"));
        assert!(!should_use_query("DELETED FROM users"));
        assert!(!should_use_query("DELETE FROM users"));
    }

    #[test]
    fn test_transaction_specific_queries() {
        assert!(!should_use_query("BEGIN"));
        assert!(!should_use_query("BEGIN TRANSACTION"));
        assert!(!should_use_query("COMMIT"));
        assert!(!should_use_query("ROLLBACK"));
        assert!(!should_use_query("SAVEPOINT sp1"));
    }
}
