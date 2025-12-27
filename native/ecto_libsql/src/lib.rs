//! `EctoLibSql`: Ecto adapter for `LibSQL`/Turso databases
//!
//! This is the root module for the `EctoLibSql` NIF (Native Implemented Function) library.
//! It declares and organizes all submodules handling different aspects of database operations.
pub mod batch;
pub mod connection;
pub mod constants;
pub mod cursor;
pub mod decode;
pub mod hooks;
pub mod metadata;
pub mod models;
pub mod query;
pub mod replication;
pub mod savepoint;
pub mod statement;
pub mod transaction;
pub mod utils;

// Re-export key types and functions for internal use
pub use constants::*;
pub use models::*;
pub use utils::{detect_query_type, should_use_query, QueryType};

// Register all NIF functions with Erlang/Elixir
// Note: The rustler::init! macro automatically discovers all #[rustler::nif] functions
rustler::init!("Elixir.EctoLibSql.Native");

#[cfg(test)]
mod tests;
