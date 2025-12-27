/// Replication and sync operations for remote replicas
///
/// This module handles replication management for LibSQL remote replica databases,
/// including frame number tracking, synchronization, and consistency operations.
/// These functions are primarily useful for multi-replica deployments where
/// read-your-writes consistency is important.
///
/// **Note on Locking**: Some functions hold Arc<Mutex<>> locks across await points.
/// This is necessary because `libsql::Database` is not cloneable, so we must maintain
/// the lock through the entire async operation to access the database instance.
/// This pattern is safe because we use `TOKIO_RUNTIME.block_on()` which executes
/// the entire async block on a dedicated thread pool, preventing deadlocks.
use crate::constants::*;
use crate::utils::{safe_lock, safe_lock_arc};
use rustler::{Atom, NifResult};

/// Get the current replication index (frame number) from a remote replica database.
///
/// The frame number represents the current state of the replica's write-ahead log.
/// This is useful for tracking replication progress and implementing read-your-writes
/// consistency.
///
/// Returns the frame number or 0 if not a replica or no frames have been applied yet.
///
/// **Note**: Uses the `replication_index()` API available in libsql 0.9.29+.
///
/// # Arguments
/// - `conn_id`: Database connection ID
///
/// Returns the current frame number (0 if not applicable)
#[rustler::nif(schedule = "DirtyIo")]
pub fn get_frame_number(conn_id: &str) -> NifResult<u64> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "get_frame_number conn_map")?;
    let client = conn_map
        .get(conn_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Connection not found")))?
        .clone();
    drop(conn_map);

    // SAFETY: We use TOKIO_RUNTIME.block_on(), which runs the future synchronously on a dedicated
    // thread pool. This prevents deadlocks that could occur if we were in a true async context
    // with std::sync::Mutex guards held across await points.
    #[allow(clippy::await_holding_lock)]
    let result = TOKIO_RUNTIME.block_on(async {
        // Lock must be held for the entire async operation since Database is not cloneable
        let client_guard = safe_lock_arc(&client, "get_frame_number client")
            .map_err(|e| format!("Failed to lock client: {:?}", e))?;

        let frame_no = client_guard
            .db
            .replication_index()
            .await
            .map_err(|e| format!("replication_index failed: {}", e))?;

        Ok::<_, String>(frame_no.unwrap_or(0))
    });

    match result {
        Ok(frame_no) => Ok(frame_no),
        Err(e) => Err(rustler::Error::Term(Box::new(e))),
    }
}

/// Sync the remote replica until a specific frame number is reached.
///
/// Waits (with timeout) for the replica to catch up to the target frame number.
/// This is useful for implementing read-your-writes consistency when you know
/// the frame number of a recent write.
///
/// **Timeout**: Operations have a default timeout to prevent indefinite blocking.
///
/// # Arguments
/// - `conn_id`: Database connection ID
/// - `frame_no`: Target frame number to sync to
///
/// Returns `:ok` when sync completes successfully, error on timeout or failure.
#[rustler::nif(schedule = "DirtyIo")]
pub fn sync_until(conn_id: &str, frame_no: u64) -> NifResult<Atom> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "sync_until conn_map")?;
    let client = conn_map
        .get(conn_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Connection not found")))?
        .clone();
    drop(conn_map);

    // SAFETY: We use TOKIO_RUNTIME.block_on(), which runs the future synchronously on a dedicated
    // thread pool. This prevents deadlocks that could occur if we were in a true async context
    // with std::sync::Mutex guards held across await points.
    #[allow(clippy::await_holding_lock)]
    let result = TOKIO_RUNTIME.block_on(async {
        // Lock must be held for the entire async operation since Database is not cloneable
        let client_guard = safe_lock_arc(&client, "sync_until client")
            .map_err(|e| format!("Failed to lock client: {:?}", e))?;

        let timeout_duration = tokio::time::Duration::from_secs(DEFAULT_SYNC_TIMEOUT_SECS);
        tokio::time::timeout(timeout_duration, client_guard.db.sync_until(frame_no))
            .await
            .map_err(|_| {
                format!(
                    "sync_until timed out after {} seconds",
                    DEFAULT_SYNC_TIMEOUT_SECS
                )
            })?
            .map_err(|e| format!("sync_until failed: {}", e))?;

        Ok::<_, String>(())
    });

    match result {
        Ok(()) => Ok(rustler::types::atom::ok()),
        Err(e) => Err(rustler::Error::Term(Box::new(e))),
    }
}

/// Flush the replicator, pushing pending writes to the remote database.
///
/// Forces any buffered writes to be sent to the remote primary database immediately.
/// Returns the new frame number after the flush completes.
///
/// **Timeout**: Operations have a default timeout to prevent indefinite blocking.
///
/// # Arguments
/// - `conn_id`: Database connection ID
///
/// Returns the frame number after flush (0 if not a replica)
#[rustler::nif(schedule = "DirtyIo")]
pub fn flush_replicator(conn_id: &str) -> NifResult<u64> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "flush_replicator conn_map")?;
    let client = conn_map
        .get(conn_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Connection not found")))?
        .clone();
    drop(conn_map);

    // SAFETY: We use TOKIO_RUNTIME.block_on(), which runs the future synchronously on a dedicated
    // thread pool. This prevents deadlocks that could occur if we were in a true async context
    // with std::sync::Mutex guards held across await points.
    #[allow(clippy::await_holding_lock)]
    let result: Result<u64, String> = TOKIO_RUNTIME.block_on(async {
        // Lock must be held for the entire async operation since Database is not cloneable
        let client_guard = safe_lock_arc(&client, "flush_replicator client")
            .map_err(|e| format!("Failed to lock client: {:?}", e))?;

        let timeout_duration = tokio::time::Duration::from_secs(DEFAULT_SYNC_TIMEOUT_SECS);
        let frame_no = tokio::time::timeout(timeout_duration, client_guard.db.flush_replicator())
            .await
            .map_err(|_| {
                format!(
                    "flush_replicator timed out after {} seconds",
                    DEFAULT_SYNC_TIMEOUT_SECS
                )
            })?
            .map_err(|e| format!("flush_replicator failed: {}", e))?;

        // Return 0 if not a replica (consistent with get_frame_number behavior)
        Ok(frame_no.unwrap_or(0))
    });

    match result {
        Ok(frame_no) => Ok(frame_no),
        Err(e) => Err(rustler::Error::Term(Box::new(e))),
    }
}

/// Get the highest frame number from write operations on this database.
///
/// This is useful for read-your-writes consistency across replicas. After performing
/// a write operation, you can get this value and pass it to `sync_until` on other
/// replicas to ensure they have caught up to your write.
///
/// Returns the max write frame number, or 0 if no writes have occurred or
/// the database doesn't track write replication index.
///
/// # Arguments
/// - `conn_id`: Database connection ID
///
/// Returns the highest write frame number (0 if not applicable)
#[rustler::nif(schedule = "DirtyIo")]
pub fn max_write_replication_index(conn_id: &str) -> NifResult<u64> {
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "max_write_replication_index conn_map")?;
    let client = conn_map
        .get(conn_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Connection not found")))?
        .clone();
    drop(conn_map);

    // This is a synchronous call, no need for async block
    let client_guard = safe_lock_arc(&client, "max_write_replication_index client")?;

    // Call max_write_replication_index() which returns Option<FrameNo>
    let max_write_frame = client_guard.db.max_write_replication_index();

    Ok(max_write_frame.unwrap_or(0))
}

/// **NOT SUPPORTED** - Freeze database operation is not implemented.
///
/// Freeze is intended to convert a remote replica to a standalone local database
/// for disaster recovery. However, this operation requires deep refactoring of
/// the connection pool architecture (taking ownership of the Database instance,
/// which is held in an Arc within connection state) and is not currently supported.
///
/// # Arguments
/// - `conn_id`: Database connection ID
///
/// Returns: `{:error, :unsupported}` - This feature is not implemented
#[rustler::nif(schedule = "DirtyIo")]
pub fn freeze_database(conn_id: &str) -> NifResult<Atom> {
    // Verify connection exists (basic validation)
    let conn_map = safe_lock(&CONNECTION_REGISTRY, "freeze_database conn_map")?;
    let _exists = conn_map
        .get(conn_id)
        .ok_or_else(|| rustler::Error::Term(Box::new("Connection not found")))?;
    drop(conn_map);

    // Always return :unsupported atom - this feature requires architectural changes
    // that have not been completed. See CLAUDE.md for implementation details.
    Err(rustler::Error::Atom("unsupported"))
}
