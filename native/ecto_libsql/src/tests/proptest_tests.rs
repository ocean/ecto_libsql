//! Property-based tests using proptest
//!
//! These tests verify invariants that should hold for all inputs,
//! helping catch edge cases that unit tests might miss.

use crate::utils::{detect_query_type, should_use_query, QueryType};
use proptest::prelude::*;

proptest! {
    /// Property: should_use_query should never panic for any valid UTF-8 string
    #[test]
    fn should_use_query_never_panics(sql in ".*") {
        let _ = should_use_query(&sql);
    }

    /// Property: detect_query_type should never panic for any valid UTF-8 string
    #[test]
    fn detect_query_type_never_panics(sql in ".*") {
        let _ = detect_query_type(&sql);
    }

    /// Property: SELECT statements should always return true from should_use_query
    #[test]
    fn select_always_uses_query(
        whitespace in r"[ \t\n\r]*",
        rest in "[^;]*"
    ) {
        let sql = format!("{whitespace}SELECT {rest}");
        prop_assert!(should_use_query(&sql), "SELECT should use query: {}", sql);
    }

    /// Property: Statements with RETURNING should use query
    #[test]
    fn returning_uses_query(
        prefix in "(INSERT|UPDATE|DELETE)[ \t]+[^;]*",
        whitespace in r"[ \t]+",
        rest in "[^;]*"
    ) {
        let sql = format!("{prefix}{whitespace}RETURNING{whitespace}{rest}");
        prop_assert!(should_use_query(&sql), "RETURNING should use query: {}", sql);
    }

    /// Property: detect_query_type is consistent with should_use_query
    #[test]
    fn query_type_consistency(sql in "[A-Za-z ]{1,100}") {
        let uses_query = should_use_query(&sql);
        let query_type = detect_query_type(&sql);

        // If it's a SELECT, should_use_query should return true
        if matches!(query_type, QueryType::Select) {
            prop_assert!(uses_query, "SELECT type should use query: {}", sql);
        }
    }

    /// Property: Empty and whitespace-only strings have consistent behaviour
    #[test]
    fn empty_and_whitespace_consistent(whitespace in r"[ \t\n\r]*") {
        // Should not panic
        let uses_query = should_use_query(&whitespace);
        let query_type = detect_query_type(&whitespace);

        // Empty/whitespace should be "Other" type
        prop_assert!(
            matches!(query_type, QueryType::Other),
            "Whitespace should be Other type, got {:?}", query_type
        );

        // Empty/whitespace should not use query (no rows returned)
        prop_assert!(
            !uses_query,
            "Whitespace should not use query"
        );
    }

    /// Property: Case insensitivity for SQL keywords
    #[test]
    fn case_insensitive_keywords(
        whitespace in r"[ \t]*",
        select_case in prop::sample::select(vec!["select", "SELECT", "Select", "sElEcT"]),
        rest in "[^;]{0,50}"
    ) {
        let sql = format!("{whitespace}{select_case} {rest}");
        prop_assert!(
            should_use_query(&sql),
            "SELECT in any case should use query: {}", sql
        );
    }

    /// Property: Very long strings don't cause issues
    #[test]
    fn long_strings_safe(
        prefix in "(SELECT|INSERT|UPDATE|DELETE)",
        padding in ".{0,1000}"
    ) {
        let sql = format!("{prefix} {padding}");
        // Should not panic or take excessive time
        let _ = should_use_query(&sql);
        let _ = detect_query_type(&sql);
    }

    /// Property: Strings with only special characters don't cause issues
    #[test]
    fn special_chars_safe(special in "[!@#$%^&*()_+=;:,.<>?~]{0,100}") {
        // Should not panic
        let _ = should_use_query(&special);
        let _ = detect_query_type(&special);
    }

    /// Property: Numeric strings don't cause issues
    #[test]
    fn numeric_strings_safe(numbers in "[0-9]{0,50}") {
        // Should not panic
        let _ = should_use_query(&numbers);
        let _ = detect_query_type(&numbers);
    }
}
