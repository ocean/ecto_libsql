# Fuzz Testing for EctoLibSql

This document describes how to run fuzz tests for the Rust NIF implementation.

## Overview

The ecto_libsql Rust code includes fuzz tests to verify that our SQL parsing and type detection functions handle arbitrary input safely without panicking.

## Prerequisites

1. **Rust nightly toolchain** - Required by cargo-fuzz
   ```bash
   rustup install nightly
   ```

2. **cargo-fuzz** - The fuzzing tool
   ```bash
   cargo install cargo-fuzz
   ```

## Available Fuzz Targets

| Target | Description |
|--------|-------------|
| `fuzz_should_use_query` | Tests the SQL query type detection (SELECT vs INSERT/UPDATE/DELETE) |
| `fuzz_detect_query_type` | Tests query categorisation into query types |
| `fuzz_sql_structured` | Tests with structured SQL-like inputs using the Arbitrary trait |

## Running Fuzz Tests

### List available targets

```bash
cd native/ecto_libsql
cargo +nightly fuzz list
```

### Run a specific fuzz target

```bash
# Run indefinitely (Ctrl+C to stop)
cargo +nightly fuzz run fuzz_should_use_query

# Run for a specific duration (e.g., 60 seconds)
cargo +nightly fuzz run fuzz_should_use_query -- -max_total_time=60

# Run for a specific number of iterations
cargo +nightly fuzz run fuzz_should_use_query -- -runs=100000
```

### Run all fuzz targets briefly (for CI)

```bash
# Quick sanity check - 10 seconds each
for target in $(cargo +nightly fuzz list); do
    cargo +nightly fuzz run "$target" -- -max_total_time=10
done
```

## Understanding Output

A successful run looks like:
```
#123456	DONE   cov: 74 ft: 250 corp: 147/6759b
Done 123456 runs in 5 second(s)
```

If a crash is found:
```
==12345== ERROR: libFuzzer: deadly signal
Crash saved to artifacts/fuzz_should_use_query/crash-...
```

## Reproducing Crashes

If a crash is found, reproduce it:

```bash
cargo +nightly fuzz run fuzz_should_use_query artifacts/fuzz_should_use_query/crash-abc123
```

## Coverage

To view coverage information:

```bash
cargo +nightly fuzz coverage fuzz_should_use_query
```

## Adding New Fuzz Targets

1. Create a new file in `fuzz/fuzz_targets/`:

```rust
#![no_main]
use libfuzzer_sys::fuzz_target;
use ecto_libsql::your_function;

fuzz_target!(|data: &[u8]| {
    if let Ok(input) = std::str::from_utf8(data) {
        let _ = your_function(input);
    }
});
```

2. Add the target to `fuzz/Cargo.toml`:

```toml
[[bin]]
name = "fuzz_your_function"
path = "fuzz_targets/fuzz_your_function.rs"
test = false
doc = false
bench = false
```

## Continuous Fuzzing

For thorough testing, consider running fuzz tests for extended periods:

```bash
# Run overnight (8 hours)
cargo +nightly fuzz run fuzz_should_use_query -- -max_total_time=28800

# Run with parallel workers
cargo +nightly fuzz run fuzz_should_use_query -- -workers=4 -max_total_time=3600
```

## Corpus Management

The fuzzer builds a corpus of interesting inputs in `fuzz/corpus/<target>/`. To reset:

```bash
rm -rf fuzz/corpus/fuzz_should_use_query
```

To minimise the corpus:

```bash
cargo +nightly fuzz cmin fuzz_should_use_query
```

## Troubleshooting

### "current package believes it's in a workspace"

The fuzz directory has its own `[workspace]` table in Cargo.toml to avoid conflicts with the parent workspace. This is expected.

### Memory issues

If the fuzzer runs out of memory, limit RSS:

```bash
cargo +nightly fuzz run fuzz_should_use_query -- -rss_limit_mb=2048
```

### Slow fuzzing

The fuzzer runs with AddressSanitizer enabled, which slows execution. For faster (but less thorough) runs:

```bash
RUSTFLAGS="-Zsanitizer=none" cargo +nightly fuzz run fuzz_should_use_query
```

## Integration with CI

Fuzz tests are run in CI with a short timeout to catch obvious issues:

```bash
cargo +nightly fuzz run fuzz_should_use_query -- -max_total_time=30
cargo +nightly fuzz run fuzz_detect_query_type -- -max_total_time=30
cargo +nightly fuzz run fuzz_sql_structured -- -max_total_time=30
```

For thorough fuzzing, consider using a dedicated fuzzing service like OSS-Fuzz.
