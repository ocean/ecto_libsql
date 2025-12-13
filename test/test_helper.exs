# Exclude :ci_only tests when running locally
# These tests (like path traversal) are only run on CI by default
ci? =
  case System.get_env("CI") do
    nil -> false
    v -> (v |> String.trim() |> String.downcase()) in ["1", "true", "yes", "y", "on"]
  end

exclude =
  if ci? do
    # Running on CI (GitHub Actions, etc.) - run all tests
    []
  else
    # Running locally - skip :ci_only tests
    [ci_only: true]
  end

ExUnit.start(exclude: exclude)

# Set logger level to :info to reduce debug output during tests
Logger.configure(level: :info)
