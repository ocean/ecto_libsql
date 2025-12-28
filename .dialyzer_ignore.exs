# Dialyzer warnings that are expected/acceptable for this project.
# These are typically due to Ecto behaviour callback mismatches or
# patterns that Dialyzer cannot fully analyse.
#
# Format: List of strings or regex patterns to match warning messages.
[
  # Ecto adapter callback type mismatches
  ~r/Function rollback\/2 has no local return/,
  ~r/Type mismatch for @callback dump_cmd/,
  ~r/Spec type mismatch in argument to callback to_constraints/,
  ~r/Type mismatch with behaviour callback to explain_query/,

  # IO list construction - this is intentional for performance
  ~r/List construction.*will produce an improper list.*second argument is/,

  # Pattern matching issues that arise from complex type unions
  ~r/The pattern can never match the type/
]
