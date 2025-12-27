#![no_main]
//! Structured SQL fuzzing
//!
//! Generates structured SQL-like inputs to maximise coverage of SQL parsing functions.
//! Uses the Arbitrary trait to create structured inputs that look more like real SQL.

use arbitrary::Arbitrary;
use ecto_libsql::{detect_query_type, should_use_query};
use libfuzzer_sys::fuzz_target;

/// SQL-like input for fuzzing
#[derive(Debug, Arbitrary)]
struct SqlInput<'a> {
    /// Optional leading whitespace
    leading_whitespace: Option<&'a str>,
    /// SQL keyword (may be mangled)
    keyword: SqlKeyword,
    /// Body of the SQL
    body: &'a str,
    /// Optional RETURNING clause
    has_returning: bool,
}

/// SQL keywords to test
#[derive(Debug, Arbitrary)]
enum SqlKeyword {
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
    Pragma,
    With,
    Explain,
    /// Random bytes as keyword
    Random(u8, u8, u8, u8, u8, u8),
}

impl SqlKeyword {
    fn as_str(&self) -> String {
        match self {
            SqlKeyword::Select => "SELECT".to_string(),
            SqlKeyword::Insert => "INSERT".to_string(),
            SqlKeyword::Update => "UPDATE".to_string(),
            SqlKeyword::Delete => "DELETE".to_string(),
            SqlKeyword::Create => "CREATE".to_string(),
            SqlKeyword::Drop => "DROP".to_string(),
            SqlKeyword::Alter => "ALTER".to_string(),
            SqlKeyword::Begin => "BEGIN".to_string(),
            SqlKeyword::Commit => "COMMIT".to_string(),
            SqlKeyword::Rollback => "ROLLBACK".to_string(),
            SqlKeyword::Pragma => "PRAGMA".to_string(),
            SqlKeyword::With => "WITH".to_string(),
            SqlKeyword::Explain => "EXPLAIN".to_string(),
            SqlKeyword::Random(a, b, c, d, e, f) => {
                format!(
                    "{}{}{}{}{}{}",
                    char::from(*a),
                    char::from(*b),
                    char::from(*c),
                    char::from(*d),
                    char::from(*e),
                    char::from(*f)
                )
            }
        }
    }
}

fuzz_target!(|input: SqlInput| {
    // Build the SQL string
    let mut sql = String::new();

    if let Some(ws) = input.leading_whitespace {
        sql.push_str(ws);
    }

    sql.push_str(&input.keyword.as_str());
    sql.push(' ');
    sql.push_str(input.body);

    if input.has_returning {
        sql.push_str(" RETURNING *");
    }

    // Test both functions - they should never panic
    let _ = should_use_query(&sql);
    let _ = detect_query_type(&sql);
});
