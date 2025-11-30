# Rust NIF Resilience Improvements

## Overview

This document describes the comprehensive error handling improvements made to the `ecto_libsql` Rust NIF (Native Implemented Function) code. The goal was to eliminate panic-prone `unwrap()` calls and replace them with proper error handling that gracefully returns errors to Elixir rather than crashing the BEAM VM.

## Problem Statement

The original codebase contained **146 `unwrap()` calls** in production code. While the Erlang/Elixir philosophy is often "let it crash," crashing at the NIF level is particularly problematic because:

1. **NIF panics crash the entire BEAM VM**, not just a single process
2. Mutex poisoning can cascade and make the system unusable
3. Users get cryptic error messages instead of actionable feedback
4. It's harder to implement proper supervision and recovery strategies

## Solution

### 1. Safe Mutex Locking Helpers

Added two helper functions to handle mutex locking with proper error propagation:

```rust
// For standard Mutex<T>
fn safe_lock<'a, T>(
    mutex: &'a Mutex<T>,
    context: &str,
) -> Result<MutexGuard<'a, T>, rustler::Error>

// For Arc<Mutex<T>> (used for shared connections)
fn safe_lock_arc<'a, T>(
    arc_mutex: &'a Arc<Mutex<T>>,
    context: &str,
) -> Result<MutexGuard<'a, T>, rustler::Error>
```

**Benefits:**
- Converts `PoisonError` into proper `rustler::Error` with context
- Includes descriptive error messages indicating where the lock failed
- Returns errors to Elixir rather than panicking
- Uses Rust's `?` operator for clean error propagation

### 2. Systematic Replacement Strategy

Every `unwrap()` call in production code was replaced with one of these patterns:

#### Pattern 1: Registry Access with Safe Locks
```rust
// Before:
let conn_map = CONNECTION_REGISTRY.lock().unwrap();

// After:
let conn_map = safe_lock(&CONNECTION_REGISTRY, "query_args conn_map")?;
```

#### Pattern 2: Nested Lock Chains
```rust
// Before (panic-prone):
client
    .lock()
    .unwrap()
    .client
    .lock()
    .unwrap()
    .query(sql, params)
    .await

// After (safe):
let client_guard = safe_lock_arc(&client, "query_args client")?;
let conn_guard = safe_lock_arc(&client_guard.client, "query_args conn")?;
conn_guard.query(sql, params).await
```

#### Pattern 3: Atom Conversion
```rust
// Before:
if mode.atom_to_string().unwrap() != "local" {

// After:
let mode_str = mode
    .atom_to_string()
    .map_err(|e| rustler::Error::Term(Box::new(format!("Invalid mode atom: {:?}", e))))?;

if mode_str != "local" {
```

#### Pattern 4: Async Block Type Conversion
```rust
// Before:
TOKIO_RUNTIME.block_on(async {
    client.lock().unwrap().db.sync().await
})

// After:
TOKIO_RUNTIME.block_on(async {
    let client_guard = safe_lock_arc(&client, "do_sync client")
        .map_err(|e| format!("{:?}", e))?;
    client_guard.db.sync().await
})
```

### 3. Functions Updated

All production NIF functions were updated:

- ✅ `begin_transaction`
- ✅ `begin_transaction_with_behavior`
- ✅ `execute_with_transaction`
- ✅ `query_with_trx_args`
- ✅ `handle_status_transaction`
- ✅ `do_sync`
- ✅ `commit_or_rollback_transaction`
- ✅ `close`
- ✅ `connect`
- ✅ `query_args`
- ✅ `ping`
- ✅ `execute_batch`
- ✅ `execute_transactional_batch`
- ✅ `prepare_statement`
- ✅ `query_prepared`
- ✅ `execute_prepared`
- ✅ `last_insert_rowid`
- ✅ `changes`
- ✅ `total_changes`
- ✅ `is_autocommit`
- ✅ `declare_cursor`
- ✅ `fetch_cursor`

### 4. Test Code Exception

Test code (inside `#[cfg(test)]` modules) still uses `unwrap()` - this is intentional and acceptable because:
- Tests are supposed to panic on failure
- Test failures don't affect production
- It keeps test code concise and readable

## Error Messages

All error messages now include context about what operation was being performed:

```rust
// Old: Generic panic message
thread 'tokio-runtime-worker' panicked at 'called `Result::unwrap()` on an `Err` value: ...'

// New: Descriptive error returned to Elixir
{:error, "Mutex poisoned in query_args client: poisoned lock: another task failed inside"}
```

## Impact

### Before
- **146 unwrap() calls** in production code
- High risk of VM crashes on mutex poisoning
- Poor error messages
- Difficult to debug NIF-level issues

### After
- **0 unwrap() calls** in production code (only in tests where appropriate)
- Graceful error handling with descriptive messages
- Errors propagate to Elixir supervision tree
- Better debugging with contextual error information

## Verification

### Rust Tests
```bash
cd native/ecto_libsql && cargo test
```
Result: **19/19 tests passing** ✅

### Elixir Tests
```bash
mix test
```
Result: **118 tests passing, 0 failures** ✅

### Static Analysis
```bash
cd native/ecto_libsql && cargo check
```
Result: **No errors, no warnings** ✅

## Example Error Flows

### Scenario 1: Poisoned Mutex
**Before:** BEAM VM crashes with cryptic panic message

**After:**
```elixir
{:error, "Mutex poisoned in begin_transaction conn_map: poisoned lock: another task failed inside"}
```
The calling Elixir process receives an error tuple and can handle it appropriately (retry, log, alert, etc.)

### Scenario 2: Invalid Connection ID
**Before:** Could panic depending on how `get()` result was used

**After:**
```elixir
{:error, "Invalid connection ID"}
```
Clean error propagation with meaningful message.

### Scenario 3: Transaction Not Found
**Before:** Panic on unwrap of `None`

**After:**
```elixir
{:error, "Transaction not found"}
```
Handled gracefully, allows for proper cleanup.

## Best Practices Established

1. **Always use safe_lock helpers** instead of `.lock().unwrap()`
2. **Provide context strings** to help debug which lock failed
3. **Use `?` operator** for clean error propagation
4. **Drop locks before async operations** to avoid holding locks across await points
5. **Convert error types** when crossing async boundaries (e.g., `rustler::Error` → `String` in async blocks)
6. **Add descriptive error messages** that help users understand what went wrong

## Future Recommendations

1. **Consider adding retry logic** for transient mutex issues
2. **Implement connection pooling statistics** to track lock contention
3. **Add telemetry events** for error conditions
4. **Consider using try_lock** with timeouts for non-critical operations
5. **Document error handling patterns** in the main AGENTS.md guide

## Migration Path for Other Projects

If you're working on another Rust NIF project with similar issues:

1. Create safe locking helpers similar to those shown above
2. Search for all `.unwrap()` calls in non-test code
3. Replace systematically, starting with connection management
4. Test thoroughly after each batch of changes
5. Use `cargo check` frequently to catch type issues early
6. Run both Rust and Elixir test suites

## Conclusion

These changes make the `ecto_libsql` NIF significantly more resilient and production-ready. Instead of crashing the BEAM VM, errors are now handled gracefully and returned to Elixir where they can be properly supervised, logged, and recovered from. This aligns with Elixir's fault-tolerance philosophy while respecting the unique constraints of NIF development.

The codebase is now safer, more maintainable, and provides better user experience through clear error messages.