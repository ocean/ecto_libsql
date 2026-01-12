# Exclude various test categories based on environment
# - :ci_only tests (like path traversal) are only run on CI by default
# - :slow tests (like stress/load tests) are excluded by default to keep test runs fast
# - :flaky tests (like concurrency tests) are excluded by default to avoid CI brittleness
# - :sqlite_limitation tests are for PostgreSQL-only behavior that doesn't work in SQLite
ci? =
  case System.get_env("CI") do
    nil -> false
    v -> (v |> String.trim() |> String.downcase()) in ["1", "true", "yes", "y", "on"]
  end

exclude =
  if ci? do
    # Running on CI (GitHub Actions, etc.) - skip flaky tests and known SQLite limitations
    [flaky: true, sqlite_limitation: true]
  else
    # Running locally - skip :ci_only, :slow, :flaky tests, and SQLite limitations
    [ci_only: true, slow: true, flaky: true, sqlite_limitation: true]
  end

ExUnit.start(exclude: exclude)

# Set logger level to :info to reduce debug output during tests
Logger.configure(level: :info)

defmodule EctoLibSql.TestHelpers do
  @moduledoc """
  Shared helpers for EctoLibSql tests.
  """

  @doc """
  Cleans up all database-related files for a given database path.

  This removes the main database file and all associated files:
  - `.db` - Main database file
  - `.db-wal` - Write-Ahead Log file
  - `.db-shm` - Shared memory file
  - `.db-journal` - Journal file (rollback journal mode)
  - `.db-info` - LibSQL/Turso replication info file

  ## Example

      on_exit(fn ->
        EctoLibSql.TestHelpers.cleanup_db_files("test.db")
      end)
  """
  @spec cleanup_db_files(String.t()) :: :ok
  def cleanup_db_files(db_path) when is_binary(db_path) do
    files = [
      db_path,
      db_path <> "-wal",
      db_path <> "-shm",
      db_path <> "-journal",
      db_path <> "-info"
    ]

    Enum.each(files, fn file ->
      File.rm(file)
    end)

    :ok
  end

  @doc """
  Cleans up all database files matching a pattern using wildcard.

  Useful for cleaning up test databases with unique IDs in their names.

  ## Example

      on_exit(fn ->
        EctoLibSql.TestHelpers.cleanup_db_files_matching("z_ecto_libsql_test-*.db")
      end)
  """
  @spec cleanup_db_files_matching(String.t()) :: :ok
  def cleanup_db_files_matching(pattern) when is_binary(pattern) do
    Path.wildcard(pattern)
    |> Enum.each(&cleanup_db_files/1)

    # Also clean up any orphaned auxiliary files
    Path.wildcard(pattern <> "-*")
    |> Enum.each(&File.rm/1)

    :ok
  end
end
