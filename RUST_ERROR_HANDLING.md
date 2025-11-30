# Rust NIF Error Handling Quick Reference

## Overview

This guide provides quick reference patterns for safe error handling in the `ecto_libsql` Rust NIF code.

## Core Principles

1. **Never use `unwrap()` in production code** - always handle errors explicitly
2. **Always provide context** - include descriptive strings in error messages
3. **Use the `?` operator** - let Rust's error propagation do the work
4. **Return errors to Elixir** - don't panic the BEAM VM

## Helper Functions

### safe_lock

Use for locking standard `Mutex<T>`:

```rust
fn safe_lock<'a, T>(
    mutex: &'a Mutex<T>,
    context: &str,
) -> Result<MutexGuard<'a, T>, rustler::Error>
```

### safe_lock_arc

Use for locking `Arc<Mutex<T>>` (shared connections):

```rust
fn safe_lock_arc<'a, T>(
    arc_mutex: &'a Arc<Mutex<T>>,
    context: &str,
) -> Result<MutexGuard<'a, T>, rustler::Error>
```

## Common Patterns

### Pattern 1: Lock a Registry

```rust
// ❌ DON'T
let conn_map = CONNECTION_REGISTRY.lock().unwrap();

// ✅ DO
let conn_map = safe_lock(&CONNECTION_REGISTRY, "function_name conn_map")?;
```

### Pattern 2: Lock Nested Mutexes

```rust
// ❌ DON'T
let result = client
    .lock()
    .unwrap()
    .client
    .lock()
    .unwrap()
    .query(sql, params)
    .await;

// ✅ DO
let client_guard = safe_lock_arc(&client, "function_name client")?;
let conn_guard = safe_lock_arc(&client_guard.client, "function_name conn")?;
let result = conn_guard.query(sql, params).await;
```

### Pattern 3: Access Registry Entry

```rust
// ❌ DON'T
let client = conn_map.get(conn_id).unwrap();

// ✅ DO
let client = conn_map
    .get(conn_id)
    .ok_or_else(|| rustler::Error::Term(Box::new("Connection not found")))?;
```

### Pattern 4: Convert Atom to String

```rust
// ❌ DON'T
let mode_str = mode.atom_to_string().unwrap();

// ✅ DO
let mode_str = mode
    .atom_to_string()
    .map_err(|e| rustler::Error::Term(Box::new(format!("Invalid mode atom: {:?}", e))))?;
```

### Pattern 5: Async Block with Locks

When inside `TOKIO_RUNTIME.block_on(async { ... })`, you need to convert `rustler::Error` to the async block's error type:

```rust
// ❌ DON'T
TOKIO_RUNTIME.block_on(async {
    let guard = safe_lock_arc(&client, "context")?; // Won't compile!
    guard.query(sql, params).await
})

// ✅ DO
TOKIO_RUNTIME.block_on(async {
    let guard = safe_lock_arc(&client, "context")
        .map_err(|e| format!("{:?}", e))?;
    guard
        .query(sql, params)
        .await
        .map_err(|e| format!("{:?}", e))
})
```

### Pattern 6: Drop Locks Before Async

Always drop locks before entering async operations to avoid deadlocks:

```rust
// ✅ DO
let conn_map = safe_lock(&CONNECTION_REGISTRY, "function_name")?;
let client = conn_map.get(conn_id).cloned()
    .ok_or_else(|| rustler::Error::Term(Box::new("Connection not found")))?;
drop(conn_map); // Release lock before async operation

TOKIO_RUNTIME.block_on(async {
    // async work here
})
```

### Pattern 7: Insert into Registry

```rust
// ❌ DON'T
TXN_REGISTRY.lock().unwrap().insert(trx_id.clone(), trx);

// ✅ DO
safe_lock(&TXN_REGISTRY, "function_name txn_registry")?
    .insert(trx_id.clone(), trx);
```

### Pattern 8: Remove from Registry

```rust
// ❌ DON'T
let trx = TXN_REGISTRY.lock().unwrap().remove(trx_id).unwrap();

// ✅ DO
let trx = safe_lock(&TXN_REGISTRY, "function_name txn_registry")?
    .remove(trx_id)
    .ok_or_else(|| rustler::Error::Term(Box::new("Transaction not found")))?;
```

### Pattern 9: Return Metadata

When returning values from async blocks that use locks:

```rust
// ✅ DO
let result = TOKIO_RUNTIME.block_on(async {
    let client_guard = safe_lock_arc(&client, "last_insert_rowid client")?;
    let conn_guard = safe_lock_arc(&client_guard.client, "last_insert_rowid conn")?;
    
    Ok::<i64, rustler::Error>(conn_guard.last_insert_rowid())
})?;

Ok(result)
```

## Error Message Guidelines

### Context Strings

Always include the function name and which lock/resource is being accessed:

```rust
// Pattern: "function_name resource_description"
safe_lock(&CONNECTION_REGISTRY, "query_args conn_map")?
safe_lock_arc(&client, "query_args client")?
safe_lock_arc(&client_guard.client, "query_args conn")?
```

### Error Messages

Make error messages actionable:

```rust
// ❌ DON'T - vague
Err(rustler::Error::Term(Box::new("Error")))

// ✅ DO - specific
Err(rustler::Error::Term(Box::new("Connection not found")))
Err(rustler::Error::Term(Box::new("Transaction not found")))
Err(rustler::Error::Term(Box::new(format!("Failed to connect: {}", e))))
```

## Checklist for New Functions

When writing a new NIF function:

- [ ] No `unwrap()` calls in production code
- [ ] All mutex locks use `safe_lock` or `safe_lock_arc`
- [ ] Context strings provided for all locks
- [ ] Registry access uses `ok_or_else` instead of `unwrap`
- [ ] Locks dropped before async operations
- [ ] Error types converted in async blocks
- [ ] Descriptive error messages
- [ ] Returns `NifResult<T>` with proper error variants

## Common Mistakes

### Mistake 1: Using `?` with Wrong Error Type

```rust
// ❌ WRONG - type mismatch in async block
TOKIO_RUNTIME.block_on(async {
    let guard = safe_lock_arc(&client, "context")?; // rustler::Error
    guard.query(sql, params).await // libsql::Error
})

// ✅ RIGHT
TOKIO_RUNTIME.block_on(async {
    let guard = safe_lock_arc(&client, "context")
        .map_err(|e| format!("{:?}", e))?; // Convert to String
    guard
        .query(sql, params)
        .await
        .map_err(|e| format!("{:?}", e)) // Convert to String
})
```

### Mistake 2: Holding Locks Across Await

```rust
// ❌ WRONG - potential deadlock
let guard = safe_lock(&REGISTRY, "context")?;
some_async_operation().await?;
guard.do_something();

// ✅ RIGHT
let data = {
    let guard = safe_lock(&REGISTRY, "context")?;
    guard.get_data().cloned()
}; // guard dropped here
some_async_operation().await?;
```

### Mistake 3: Nested Unwraps

```rust
// ❌ WRONG
conn.lock().unwrap().client.lock().unwrap()

// ✅ RIGHT
let conn_guard = safe_lock_arc(&conn, "context conn")?;
let client_guard = safe_lock_arc(&conn_guard.client, "context client")?;
```

## Testing

### Unit Tests Can Use Unwrap

Test code is allowed to use `unwrap()` for simplicity:

```rust
#[cfg(test)]
mod tests {
    #[test]
    fn test_something() {
        let db = Builder::new_local("test.db").build().await.unwrap();
        let conn = db.connect().unwrap();
        // ... test code can use unwrap()
    }
}
```

### Integration Tests

Run both Rust and Elixir tests:

```bash
# Rust tests
cd native/ecto_libsql && cargo test

# Elixir tests
mix test

# Static analysis
cd native/ecto_libsql && cargo check
```

## Resources

- [Rustler Error Handling](https://github.com/rusterlium/rustler#error-handling)
- [Rust Error Handling Guide](https://doc.rust-lang.org/book/ch09-00-error-handling.html)
- [Mutex Poisoning](https://doc.rust-lang.org/std/sync/struct.Mutex.html#poisoning)

## Summary

**Golden Rule:** If you see `.unwrap()` in production code, replace it with proper error handling using the patterns above. Your future self (and your users) will thank you!