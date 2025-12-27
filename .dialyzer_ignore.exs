# Dialyzer warnings that are expected/acceptable for this project.
# These are typically due to Ecto behaviour callback mismatches or
# patterns that Dialyzer cannot fully analyse.

# Ecto adapter callback type mismatches
{"lib/ecto/adapters/libsql.ex", "Function rollback/2 has no local return."}
{"lib/ecto/adapters/libsql.ex", "Type mismatch for @callback dump_cmd."}
{"lib/ecto/adapters/libsql/connection.ex", "Spec type mismatch in argument to callback to_constraints."}
{"lib/ecto/adapters/libsql/connection.ex", "Type mismatch with behaviour callback to explain_query/4."}

# IO list construction - this is intentional for performance
{"lib/ecto/adapters/libsql/connection.ex", "List construction (cons) will produce an improper list, because its second argument is <<_::64>>."}

# Pattern matching issues that arise from complex type unions
{"lib/ecto/adapters/libsql.ex", ~r/The pattern can never match the type/}
