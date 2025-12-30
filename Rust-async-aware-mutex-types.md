Rust-async-aware-mutex-types.md

How would we fix wait_holding_lock clipper warnings in a future PR by using async-aware Mutex types??

Good question! Let me explain how to fix await_holding_lock warnings with async-aware Mutex types:

How to Fix await_holding_lock with Async-Aware Mutex

The current code uses std::sync::Mutex with #[allow(clippy::await_holding_lock)] because we're inside TOKIO_RUNTIME.block_on() which runs synchronously. To properly fix this:

Option 1: Use tokio::sync::Mutex
// Current (std::sync::Mutex - requires #[allow])
use std::sync::Mutex;
let guard = mutex.lock().unwrap();
result.await  // ⚠️ clippy warning

// Fixed (tokio::sync::Mutex - async-native)
use tokio::sync::Mutex;
let guard = mutex.lock().await;  // Async lock acquisition
result.await  // ✅ No warning - designed for this pattern

Option 2: Restructure to Drop Lock Before Await
// Current pattern
let guard = mutex.lock();
let result = guard.query(sql).await;  // Lock held across await

// Fixed pattern
let connection = {
    let guard = mutex.lock();
    guard.connection.clone()  // Clone what we need
};  // Lock dropped here
let result = connection.query(sql).await;  // No lock held

Why We Currently Use #[allow]
The codebase uses std::sync::Mutex because:
LibSQL's Connection type is not Send + Sync in all contexts
tokio::sync::Mutex requires the guarded value to be Send
The block_on() pattern is actually safe - it runs synchronously

A proper refactoring would require:
- Changing all Arc<Mutex<T>> to Arc<tokio::sync::Mutex<T>>
- Updating all lock acquisitions to be async (.lock().await)
- Testing thoroughly for any Send/Sync issues with LibSQL types