{"lib/ecto/adapters/libsql.ex", "Function rollback/2 has no local return."}
{"lib/ecto/adapters/libsql.ex", "The pattern can never match the type
  {:error, %EctoLibSql.Error{:__exception__ => true, :message => _, :sqlite => nil},
   %EctoLibSql.State{:conn_id => _, _ => _}}
  | {:ok, %EctoLibSql.Query{:statement => _, _ => _},
     %EctoLibSql.Result{
       :columns => _,
       :command =>
         :begin
         | :commit
         | :create
         | :delete
         | :insert
         | :rollback
         | :select
         | :unknown
         | :update,
       :num_rows => _,
       :rows => _
     }, %EctoLibSql.State{:conn_id => _, _ => _}}
."}
{"lib/ecto/adapters/libsql.ex", "Type mismatch for @callback dump_cmd."}
{"lib/ecto/adapters/libsql/connection.ex", "Spec type mismatch in argument to callback to_constraints."}
{"lib/ecto/adapters/libsql/connection.ex", "Type mismatch with behaviour callback to explain_query/4."}
{"lib/ecto/adapters/libsql/connection.ex", "List construction (cons) will produce an improper list, because its second argument is <<_::64>>."}
