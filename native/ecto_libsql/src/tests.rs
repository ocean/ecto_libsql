//! Unit and integration tests for ecto_libsql
//!
//! This module contains all tests for the NIF implementation, organized into logical groups.

use super::*;
use std::fs;

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
    //
    // The following tests document **known limitations** of should_use_query().
    // These are SAFE false positives (using query() when execute() would suffice).
    //
    // Full SQL parsing (to skip comments/strings) would be prohibitively expensive
    // for this performance-critical path. The trade-off favours safety over perfection.

    #[test]
    fn test_returning_in_block_comment_false_positive() {
        // KNOWN LIMITATION: RETURNING inside block comments is detected as a match.
        // This is a SAFE false positive - using query() works correctly, just with
        // slightly more overhead than execute() would have.
        //
        // Example: SELECT * /* RETURNING */ FROM users
        // Current behavior: Returns true (false positive)
        // Correct behavior: Should return false
        // Impact: Minimal - query() handles SELECT correctly
        //
        // TODO: Future refactor to skip block comments (/* ... */) during keyword detection
        // would eliminate this false positive. See "Recommendations for Future Improvements"
        // section at end of this test module for details.
        assert!(should_use_query("SELECT * /* RETURNING */ FROM users"));

        // Another example with RETURNING in comment
        assert!(should_use_query(
            "UPDATE users SET name = 'Alice' /* RETURNING id */ WHERE id = 1"
        ));

        // Document the specific case from feedback: SELECT with RETURNING in comment
        // Currently returns true (uses query()), which is safe but suboptimal.
        // Ideally this should return false (use execute()), but we'd need comment-skipping
        // logic to achieve that.
        let result = should_use_query("SELECT * /* RETURNING */ FROM users");
        // ASSERTION: Current behavior (true) is documented as a known limitation
        // If this assertion fails after a refactor to skip comments, update to:
        // assert!(!should_use_query("SELECT * /* RETURNING */ FROM users"));
        assert_eq!(
            result, true,
            "Known limitation: RETURNING in block comments is detected"
        );
    }

    #[test]
    fn test_returning_in_string_literal_mixed_behavior() {
        // PARTIALLY GOOD: String literals are correctly NOT matched when RETURNING
        // is not surrounded by whitespace.
        //
        // Example: INSERT INTO t VALUES ('RETURNING')
        // The 'R' in 'RETURNING' is preceded by a quote, not whitespace.
        // Current behavior: Returns false (correct!)
        assert!(!should_use_query("INSERT INTO t VALUES ('RETURNING')"));

        // Even with space before the string
        assert!(!should_use_query("INSERT INTO t VALUES ( 'RETURNING')"));

        // Double-quoted strings also work correctly when not surrounded by whitespace
        assert!(!should_use_query(
            "INSERT INTO t (col) VALUES (\"RETURNING\")"
        ));

        // LIMITATION: If RETURNING appears inside a string with whitespace before AND after,
        // it IS detected as a false positive. This is SAFE but suboptimal.
        //
        // Example: VALUES ('Error: RETURNING failed')
        // The space before 'R' and after 'G' cause it to match.
        // Current behavior: Returns true (false positive, but safe)
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
        // of the SQL statement for SELECT, and quotes aren't valid SQL starters.
        //
        // Example: INSERT INTO t VALUES ('SELECT * FROM users')
        // This correctly returns false (INSERT, no RETURNING).
        assert!(!should_use_query(
            "INSERT INTO t VALUES ('SELECT * FROM users')"
        ));
    }

    // ===== CTE (Common Table Expressions) Tests =====
    //
    // **OUT OF SCOPE**: Ecto does not generate CTE queries. These would need to
    // be written as raw SQL fragments. The current implementation does NOT detect
    // CTEs (returns false) because they start with WITH, not SELECT.
    //
    // If CTEs were supported, they would need special detection logic to check
    // for WITH keyword at the start. For now, this is not implemented.

    #[test]
    fn test_cte_with_select_not_detected() {
        // CTEs are NOT detected by the current implementation.
        // These start with WITH, not SELECT, so they return false.
        //
        // Impact: If a developer writes raw CTE SQL, they would need to use
        // Repo.query() directly instead of relying on Ecto to detect it.
        // This is acceptable because Ecto doesn't generate CTEs.
        assert!(!should_use_query(
            "WITH active_users AS (SELECT * FROM users WHERE active = 1) SELECT * FROM active_users"
        ));

        assert!(!should_use_query(
            "WITH RECURSIVE cte AS (SELECT 1 AS n UNION ALL SELECT n+1 FROM cte WHERE n < 10) SELECT * FROM cte"
        ));

        // Multiple CTEs also not detected
        assert!(!should_use_query(
            "WITH
                admins AS (SELECT * FROM users WHERE role = 'admin'),
                posts AS (SELECT * FROM posts WHERE published = 1)
            SELECT * FROM admins JOIN posts"
        ));
    }

    #[test]
    fn test_cte_with_insert_returning_detected_via_returning() {
        // CTE with INSERT...RETURNING IS detected, but only because of the
        // RETURNING keyword, not because it's recognized as a CTE.
        //
        // This happens to work correctly (using query() is the right choice
        // for CTEs), but it's coincidental rather than intentional.
        assert!(should_use_query(
            "WITH inserted AS (INSERT INTO users (name) VALUES ('Alice') RETURNING id) SELECT * FROM inserted"
        ));
    }

    // ===== EXPLAIN Query Tests =====
    //
    // **OUT OF SCOPE**: Ecto does not generate EXPLAIN queries. These are
    // typically used manually for query analysis/debugging. EXPLAIN queries
    // always return rows (the query plan), but the current implementation
    // only detects SELECT/RETURNING keywords.
    //
    // Impact: EXPLAIN-prefixed statements are NOT detected (they start with
    // EXPLAIN, not SELECT/RETURNING). EXPLAIN SELECT, EXPLAIN INSERT, etc.
    // all return false. Developers must use Repo.query() directly for EXPLAIN queries.
    // This is acceptable since EXPLAIN is for debugging/analysis, not production code.

    #[test]
    fn test_explain_select_not_detected() {
        // EXPLAIN SELECT is NOT detected because it starts with EXPLAIN, not SELECT.
        // The SELECT keyword appears later in the statement.
        //
        // Impact: Developers using EXPLAIN SELECT must explicitly use Repo.query().
        // This is acceptable since EXPLAIN is for debugging, not production code.
        assert!(!should_use_query("EXPLAIN SELECT * FROM users"));
        assert!(!should_use_query(
            "EXPLAIN QUERY PLAN SELECT * FROM users WHERE id = 1"
        ));
    }

    #[test]
    fn test_explain_insert_not_detected() {
        // EXPLAIN INSERT (without RETURNING) is not detected.
        // EXPLAIN is out of scope - it's used manually for debugging, not in production.
        assert!(!should_use_query(
            "EXPLAIN INSERT INTO users VALUES (1, 'Alice')"
        ));

        // However, if RETURNING is added, it IS detected because of the RETURNING keyword.
        // This is a side effect of RETURNING detection, not EXPLAIN recognition.
        assert!(should_use_query(
            "EXPLAIN INSERT INTO users VALUES (1, 'Alice') RETURNING id"
        ));
    }

    #[test]
    fn test_explain_update_delete_not_detected() {
        // EXPLAIN UPDATE/DELETE without RETURNING are not detected.
        // EXPLAIN queries start with the EXPLAIN keyword, which is out of scope.
        assert!(!should_use_query(
            "EXPLAIN UPDATE users SET name = 'Bob' WHERE id = 1"
        ));
        assert!(!should_use_query("EXPLAIN DELETE FROM users WHERE id = 1"));

        // With RETURNING, they ARE detected via the RETURNING keyword.
        // This is acceptable - developers using EXPLAIN for debugging can add RETURNING
        // if needed, or use Repo.query() directly for EXPLAIN without RETURNING.
        assert!(should_use_query(
            "EXPLAIN UPDATE users SET name = 'Bob' WHERE id = 1 RETURNING id"
        ));
    }

    // ===== Recommendations for Future Improvements =====
    //
    // If stricter accuracy is needed in the future, consider these follow-up refactors:
    //
    // 1. **Comment Skipping (PRIORITY: Medium)**
    //    Eliminate false positives for keywords inside block comments (/* ... */).
    //
    //    Current behavior: Keywords in comments are detected (safe false positives)
    //    Proposed fix: Add pre-processing to skip block comments before keyword detection
    //
    //    Example that would improve:
    //      - "SELECT * /* RETURNING */ FROM users" currently returns true
    //        Should return false (SELECT detected at start is more important)
    //
    //    Implementation sketch:
    //    ```rust
    //    fn skip_block_comments(sql: &str) -> String {
    //        let mut result = String::new();
    //        let mut chars = sql.chars().peekable();
    //        while let Some(c) = chars.next() {
    //            if c == '/' && chars.peek() == Some(&'*') {
    //                chars.next(); // consume '*'
    //                // Skip until we find '*/'
    //                loop {
    //                    match chars.next() {
    //                        Some('*') if chars.peek() == Some(&'/') => {
    //                            chars.next(); // consume '/'
    //                            break;
    //                        }
    //                        None => break,
    //                        _ => {}
    //                    }
    //                }
    //                result.push(' '); // Replace comment with space
    //            } else {
    //                result.push(c);
    //            }
    //        }
    //        result
    //    }
    //    ```
    //
    // 2. **String Literal Skipping (PRIORITY: Low)**
    //    Skip string literals ('...' and "...") to avoid matching keywords in strings.
    //    More complex than comment skipping due to SQL escape sequences.
    //    Benefit: Minimal (current behavior is already safe due to whitespace requirement)
    //
    // 3. **EXPLAIN Detection (PRIORITY: Low)**
    //    Add special handling for EXPLAIN queries, which always return rows.
    //    Current behavior: EXPLAIN without SELECT/RETURNING returns false (suboptimal)
    //    Benefit: Helps developers using EXPLAIN for query analysis (not production code)
    //
    // 4. **WITH Detection (CTE Support) (PRIORITY: Low)**
    //    Explicitly detect WITH keyword at the start to handle Common Table Expressions.
    //    Current behavior: CTEs without RETURNING return false (suboptimal)
    //    Impact: Ecto doesn't generate CTEs, so this is only for raw SQL
    //
    // Trade-off: All improvements add complexity and reduce performance. The current
    // simple implementation is fast and safe (false positives are acceptable).
    //
    // **Performance Budget**: The should_use_query() function runs on every SQL operation.
    // Any enhancement must maintain O(n) performance with minimal constant factors.

    #[test]
    fn test_returning_at_different_positions() {
        assert!(should_use_query(
            "INSERT INTO users (name, email) VALUES ('Alice', 'alice@example.com') RETURNING id"
        ));
        assert!(should_use_query(
            "UPDATE users SET name = 'Bob' WHERE id = 1 RETURNING id, name, email"
        ));
        // RETURNING as last word
        assert!(should_use_query(
            "INSERT INTO users (id) VALUES (1) RETURNING"
        ));
    }

    #[test]
    fn test_complex_real_world_queries() {
        // Ecto-generated INSERT with RETURNING
        assert!(should_use_query(
            "INSERT INTO \"users\" (\"name\",\"email\",\"inserted_at\",\"updated_at\") VALUES ($1,$2,$3,$4) RETURNING \"id\""
        ));

        // Ecto-generated UPDATE with RETURNING
        assert!(should_use_query(
            "UPDATE \"users\" SET \"name\" = $1, \"updated_at\" = $2 WHERE \"id\" = $3 RETURNING \"id\",\"name\",\"email\",\"inserted_at\",\"updated_at\""
        ));

        // Ecto-generated DELETE without RETURNING
        assert!(!should_use_query("DELETE FROM \"users\" WHERE \"id\" = $1"));

        // Complex SELECT
        assert!(should_use_query(
            "SELECT u0.\"id\", u0.\"name\", u0.\"email\" FROM \"users\" AS u0 WHERE (u0.\"active\" = $1) ORDER BY u0.\"name\" LIMIT $2"
        ));
    }

    // ===== Performance Characteristics Tests =====
    // These don't test correctness, but verify the function handles edge cases

    #[test]
    fn test_long_sql_statement() {
        let long_select = format!(
            "SELECT {} FROM users",
            (0..1000)
                .map(|i| format!("col{}", i))
                .collect::<Vec<_>>()
                .join(", ")
        );
        assert!(should_use_query(&long_select));

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
    //
    // These tests verify the fix for the routing issue where transactional SELECTs
    // were previously being misrouted to execute_with_transaction() instead of
    // query_with_trx_args(). The fix ensures all SELECT queries (whether with or
    // without RETURNING) are routed to the query path, which correctly returns rows.
    //
    // See: https://github.com/ocean/ecto_libsql/issues/[issue-number]
    // For context on the original bug.

    #[test]
    fn test_select_alone_requires_query_path() {
        // Plain SELECT without RETURNING must use query path (returns rows)
        // This was the core bug: it was being incorrectly routed to execute_with_transaction
        assert!(should_use_query("SELECT * FROM users"));
        assert!(should_use_query("SELECT id, name FROM users WHERE active = 1"));
        assert!(should_use_query("SELECT COUNT(*) FROM users"));
    }

    #[test]
    fn test_select_various_forms() {
        // All SELECT variants must use query path
        assert!(should_use_query("SELECT 1"));
        assert!(should_use_query("SELECT 1 AS num"));
        assert!(should_use_query("SELECT NULL"));
        assert!(should_use_query(
            "SELECT u.id, u.name, COUNT(p.id) FROM users u LEFT JOIN posts p ON u.id = p.user_id GROUP BY u.id"
        ));
    }

    #[test]
    fn test_select_with_subqueries() {
        // Subqueries start with SELECT but the function looks at the first keyword
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
        // This documents that SELECT takes priority (detected first)
        assert!(should_use_query(
            "SELECT * FROM users RETURNING id"
        ));
    }

    #[test]
    fn test_transactional_select_distinction_from_insert_update_delete() {
        // Core distinction for the fix:
        // - SELECT -> always use query path
        // - INSERT/UPDATE/DELETE without RETURNING -> use execute path
        // - INSERT/UPDATE/DELETE with RETURNING -> use query path

        // SELECT is always query path
        assert!(should_use_query("SELECT * FROM users"));

        // INSERT/UPDATE/DELETE without RETURNING: execute path
        assert!(!should_use_query("INSERT INTO users (name) VALUES ('Alice')"));
        assert!(!should_use_query("UPDATE users SET name = 'Bob' WHERE id = 1"));
        assert!(!should_use_query("DELETE FROM users WHERE id = 1"));

        // INSERT/UPDATE/DELETE with RETURNING: query path
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
        // SELECT with inline comments should be detected
        assert!(should_use_query("SELECT /* get all users */ * FROM users"));
        assert!(should_use_query(
            "SELECT id, -- user id\n       name -- user name\nFROM users"
        ));

        // SELECT with comments and RETURNING (edge case, unusual but documented)
        assert!(should_use_query(
            "SELECT * /* RETURNING */ FROM users"
        ));
    }

    #[test]
    fn test_select_edge_case_with_string_literals() {
        // String literals containing keywords shouldn't confuse detection
        // since we check the first non-whitespace token
        assert!(should_use_query(
            "SELECT 'RETURNING' AS literal FROM users"
        ));
        assert!(should_use_query(
            "SELECT 'INSERT' AS keyword_string FROM users"
        ));
        assert!(should_use_query(
            "SELECT message FROM logs WHERE msg = 'SELECT * FROM other_table'"
        ));
    }

    #[test]
    fn test_multiline_select_in_transaction_context() {
        // Real-world multiline SELECT queries that might be used in transactions
        assert!(should_use_query(
            "SELECT u.id,
                   u.name,
                   u.email
            FROM users u
            WHERE u.active = 1
            ORDER BY u.created_at DESC
            LIMIT 10"
        ));

        // Another multiline example with WHERE clauses
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
        // This is a limitation but acceptable since Ecto doesn't generate CTEs.
        // However, if a CTE includes SELECT, RETURNING, the function will detect those.
        assert!(!should_use_query(
            "WITH active_users AS (SELECT * FROM users WHERE active = 1) SELECT * FROM active_users"
        ));

        // But if there's an explicit SELECT before WITH (unusual), it would be detected
        // This is an edge case that doesn't happen in practice
    }

    #[test]
    fn test_explain_queries_not_detected_as_select() {
        // EXPLAIN queries don't start with SELECT, so they're not detected
        // This is a known limitation - EXPLAIN always returns rows but isn't detected
        assert!(!should_use_query("EXPLAIN SELECT * FROM users"));
        assert!(!should_use_query(
            "EXPLAIN QUERY PLAN SELECT * FROM users WHERE id = 1"
        ));
    }

    #[test]
    fn test_union_queries_detected_via_first_select() {
        // UNION queries start with SELECT
        assert!(should_use_query(
            "SELECT id FROM users UNION SELECT id FROM admins"
        ));
        assert!(should_use_query(
            "SELECT * FROM users WHERE active = 1 UNION ALL SELECT * FROM archived_users"
        ));
    }

    #[test]
    fn test_case_sensitivity_and_keyword_boundary() {
        // Ensure we're checking keyword boundaries, not substring matches
        assert!(!should_use_query("SELECTED FROM users")); // "SELECTED" is not "SELECT"
        assert!(should_use_query("SELECT * FROM users")); // "SELECT" with whitespace after is valid

        // UPDATE vs UPDATED
        assert!(!should_use_query("UPDATED users SET x = 1"));
        assert!(!should_use_query("UPDATE users SET x = 1")); // No RETURNING, so false

        // DELETE vs DELETED
        assert!(!should_use_query("DELETED FROM users"));
        assert!(!should_use_query("DELETE FROM users")); // No RETURNING, so false
    }

    #[test]
    fn test_transaction_specific_queries() {
        // Transaction control queries (not SELECT, not RETURNING)
        assert!(!should_use_query("BEGIN"));
        assert!(!should_use_query("BEGIN TRANSACTION"));
        assert!(!should_use_query("COMMIT"));
        assert!(!should_use_query("ROLLBACK"));
        assert!(!should_use_query("SAVEPOINT sp1"));
    }
}

/// Integration tests with a real SQLite database
///
/// These tests require libsql to be working and will create temporary databases.
/// They verify that the actual database operations work correctly with parameter
/// binding, transactions, and various data types.
mod integration_tests {
    use super::*;

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
        let mut rows1 = stmt1.query(vec![Value::Integer(1)]).await.unwrap();
        let row1 = rows1.next().await.unwrap().unwrap();
        assert_eq!(row1.get::<String>(0).unwrap(), "Alice");

        // Test prepared statement with second parameter (prepare again, mimicking NIF behavior)
        let stmt2 = conn
            .prepare("SELECT name FROM users WHERE id = ?1")
            .await
            .unwrap();
        let mut rows2 = stmt2.query(vec![Value::Integer(2)]).await.unwrap();
        let row2 = rows2.next().await.unwrap().unwrap();
        assert_eq!(row2.get::<String>(0).unwrap(), "Bob");

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
}

/// Tests for registry management
///
/// These tests verify that the global registries (for connections, transactions,
/// statements, and cursors) are properly initialized and accessible.
mod registry_tests {
    use super::*;

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
}
