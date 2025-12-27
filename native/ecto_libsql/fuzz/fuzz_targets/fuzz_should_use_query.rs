#![no_main]
//! Fuzz test for should_use_query function
//!
//! This function parses SQL strings to determine if they should use query() or execute().
//! It's exposed to potentially untrusted SQL input, so it must handle all inputs safely.

use ecto_libsql::should_use_query;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    // Convert bytes to string (if valid UTF-8)
    if let Ok(sql) = std::str::from_utf8(data) {
        // The function should never panic, regardless of input
        let _ = should_use_query(sql);
    }
});
