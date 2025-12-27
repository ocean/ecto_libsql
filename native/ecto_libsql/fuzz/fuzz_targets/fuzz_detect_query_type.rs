#![no_main]
//! Fuzz test for detect_query_type function
//!
//! This function parses SQL strings to categorise them into query types.
//! It must handle all inputs safely without panicking.

use ecto_libsql::detect_query_type;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    // Convert bytes to string (if valid UTF-8)
    if let Ok(sql) = std::str::from_utf8(data) {
        // The function should never panic, regardless of input
        let _ = detect_query_type(sql);
    }
});
