/// Hook management for EctoLibSql
///
/// This module implements database hooks for monitoring and controlling database operations.
/// Hooks allow Elixir processes to receive notifications about database changes and control access.
///
/// **CURRENT STATUS**: Both update hooks and authorizer hooks are currently **NOT SUPPORTED**
/// due to fundamental threading limitations with Rustler and the BEAM VM.
use rustler::{Atom, Env, LocalPid, NifResult};

/// Set update hook for a connection
///
/// **NOT SUPPORTED** - Update hooks require sending messages from managed BEAM threads,
/// which is not allowed by Rustler's threading model.
///
/// # Why Not Supported
///
/// SQLite's update hook callback is called synchronously during INSERT/UPDATE/DELETE operations,
/// and runs on the same thread executing the SQL statement. In our NIF implementation:
/// 1. SQL execution happens on Erlang scheduler threads (managed by BEAM)
/// 2. Rustler's `OwnedEnv::send_and_clear()` can ONLY be called from unmanaged threads
/// 3. Calling `send_and_clear()` from a managed thread causes a panic: "current thread is managed"
///
/// This is a fundamental limitation of mixing NIF callbacks with Erlang's threading model.
///
/// # Alternatives
///
/// For change data capture and real-time updates, consider:
///
/// 1. **Application-level events** - Emit events from your Ecto repos:
///
///     ```elixir
///     defmodule MyApp.Repo do
///       def insert(changeset, opts \\ []) do
///         case Ecto.Repo.insert(__MODULE__, changeset, opts) do
///           {:ok, record} = result ->
///             Phoenix.PubSub.broadcast(MyApp.PubSub, "db_changes", {:insert, record})
///             result
///           error -> error
///         end
///       end
///     end
///     ```
///
/// 2. **Database triggers** - Use SQLite triggers to log changes to a separate table:
///
///     ```sql
///     CREATE TRIGGER users_audit_insert AFTER INSERT ON users
///     BEGIN
///       INSERT INTO audit_log (action, table_name, row_id, timestamp)
///       VALUES ('insert', 'users', NEW.id, datetime('now'));
///     END;
///     ```
///
/// 3. **Polling-based CDC** - Periodically query for changes using timestamps or version columns
///
/// 4. **Phoenix.Tracker** - Track state changes at the application level
///
/// # Arguments
/// - `_conn_id` - Connection identifier (ignored)
/// - `_pid` - PID for callbacks (ignored)
///
/// # Returns
/// - `{:error, :unsupported}` - Always returns unsupported
#[rustler::nif]
pub fn set_update_hook(env: Env, _conn_id: &str, _pid: LocalPid) -> NifResult<(Atom, Atom)> {
    Ok((
        Atom::from_str(env, "error")?,
        Atom::from_str(env, "unsupported")?,
    ))
}

/// Clear update hook for a connection
///
/// **NOT SUPPORTED** - Update hooks are not currently implemented.
///
/// # Arguments
/// - `_conn_id` - Connection identifier (ignored)
///
/// # Returns
/// - `{:error, :unsupported}` - Always returns unsupported
#[rustler::nif]
pub fn clear_update_hook(env: Env, _conn_id: &str) -> NifResult<(Atom, Atom)> {
    Ok((
        Atom::from_str(env, "error")?,
        Atom::from_str(env, "unsupported")?,
    ))
}

/// Set authorizer hook for a connection
///
/// **NOT SUPPORTED** - Authorizer hooks require synchronous bidirectional communication
/// between Rust and Elixir, which is not feasible with Rustler's threading model.
///
/// # Why Not Supported
///
/// SQLite's authorizer callback is called synchronously during query compilation and expects
/// an immediate response (Allow/Deny/Ignore). This would require:
/// 1. Sending a message from Rust to Elixir
/// 2. Blocking the Rust thread waiting for a response
/// 3. Receiving the response from Elixir
///
/// This pattern is not safe with Rustler because:
/// - The callback runs on a SQLite thread (potentially holding locks)
/// - Blocking on Erlang scheduler threads can cause deadlocks
/// - No safe way to do synchronous Rust→Elixir→Rust calls
///
/// # Alternatives
///
/// For row-level security and access control, consider:
///
/// 1. **Application-level authorization** - Check permissions in Elixir before queries:
///
///     ```elixir
///     defmodule MyApp.Auth do
///       def can_access?(user, table, action) do
///         # Check user permissions
///       end
///     end
///
///     def get_user(id, current_user) do
///       if MyApp.Auth.can_access?(current_user, "users", :read) do
///         Repo.get(User, id)
///       else
///         {:error, :unauthorized}
///       end
///     end
///     ```
///
/// 2. **Database views** - Create views with WHERE clauses for different user levels:
///
///     ```sql
///     CREATE VIEW user_visible_posts AS
///     SELECT * FROM posts WHERE user_id = current_user_id();
///     ```
///
/// 3. **Query rewriting** - Modify queries in Elixir to include authorization constraints:
///
///     ```elixir
///     defmodule MyApp.Repo do
///       def all(queryable, current_user) do
///         queryable
///         |> apply_tenant_filter(current_user)
///         |> Ecto.Repo.all()
///       end
///     end
///     ```
///
/// 4. **Connection-level restrictions** - Use different database connections with different privileges
///
/// # Arguments
/// - `_conn_id` - Connection identifier (ignored)
/// - `_pid` - PID for callbacks (ignored)
///
/// # Returns
/// - `{:error, :unsupported}` - Always returns unsupported
#[rustler::nif]
pub fn set_authorizer(env: Env, _conn_id: &str, _pid: LocalPid) -> NifResult<(Atom, Atom)> {
    Ok((
        Atom::from_str(env, "error")?,
        Atom::from_str(env, "unsupported")?,
    ))
}

/// Determine if a SQL query should use the query path (returns rows) or execute path (no rows)
///
/// This is used by the Elixir adapter to route queries correctly:
/// - SELECT, EXPLAIN, WITH, and RETURNING clauses return rows → use query path
/// - INSERT, UPDATE, DELETE (without RETURNING) don't return rows → use execute path
///
/// # Arguments
/// - `sql` - SQL statement to analyze
///
/// # Returns
/// - `true` - Query returns rows, should use query path
/// - `false` - Query doesn't return rows, should use execute path
#[rustler::nif]
pub fn should_use_query_path(sql: String) -> bool {
    crate::should_use_query(&sql)
}
