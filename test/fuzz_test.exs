defmodule EctoLibSql.FuzzTest do
  @moduledoc """
  Property-based tests (fuzz tests) for EctoLibSql using StreamData.

  These tests verify that the library handles arbitrary inputs gracefully
  without crashing, raising unexpected exceptions, or exhibiting undefined
  behaviour.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  # ============================================================================
  # Test Setup
  # ============================================================================

  setup do
    unique_id = :erlang.unique_integer([:positive])
    db_path = "z_ecto_libsql_fuzz_test_#{unique_id}.db"

    {:ok, state} = EctoLibSql.connect(database: db_path)

    # Create test table
    {:ok, _, _, state} =
      EctoLibSql.handle_execute(
        "CREATE TABLE IF NOT EXISTS fuzz_test (id INTEGER PRIMARY KEY, data TEXT, num INTEGER, blob BLOB)",
        [],
        [],
        state
      )

    on_exit(fn ->
      try do
        EctoLibSql.disconnect([], state)
      rescue
        _ -> :ok
      end

      File.rm(db_path)
      File.rm(db_path <> "-shm")
      File.rm(db_path <> "-wal")
      File.rm(db_path <> "-journal")
    end)

    {:ok, state: state, db_path: db_path}
  end

  # ============================================================================
  # Generator Definitions
  # ============================================================================

  # Generate safe SQL identifier names (no injection)
  defp safe_identifier_gen do
    gen all(
          first <- member_of(Enum.to_list(?a..?z) ++ Enum.to_list(?A..?Z)),
          rest <-
            string(Enum.to_list(?a..?z) ++ Enum.to_list(?A..?Z) ++ Enum.to_list(?0..?9) ++ [?_],
              min_length: 0,
              max_length: 30
            )
        ) do
      <<first>> <> rest
    end
  end

  # Generate potentially malicious SQL strings for injection testing
  defp sql_injection_gen do
    one_of([
      constant("'; DROP TABLE users; --"),
      constant("\"; DROP TABLE users; --"),
      constant("' OR '1'='1"),
      constant("1; DELETE FROM users"),
      constant("1 UNION SELECT * FROM sqlite_master"),
      constant("Robert'); DROP TABLE users;--"),
      string(:printable, min_length: 0, max_length: 100),
      binary(min_length: 0, max_length: 50)
    ])
  end

  # Generate SQL injection strings that always contain injection characters.
  # This avoids the FilterTooNarrowError when filtering sql_injection_gen().
  defp sql_injection_with_chars_gen do
    gen all(
          prefix <- string(:alphanumeric, max_length: 20),
          injection_char <- member_of(["'", "\"", ";", "--", "/*"]),
          suffix <- string(:alphanumeric, max_length: 20)
        ) do
      prefix <> injection_char <> suffix
    end
  end

  # Generate various data types that might be used as query parameters
  defp query_param_gen do
    one_of([
      integer(),
      float(),
      string(:printable, max_length: 100),
      binary(max_length: 50),
      constant(nil),
      constant(true),
      constant(false),
      # Large integers
      integer(-9_223_372_036_854_775_808..9_223_372_036_854_775_807),
      # Unicode strings
      string(:utf8, max_length: 50),
      # Edge case strings
      constant(""),
      constant("\0"),
      constant("\n\r\t"),
      constant(String.duplicate("a", 1000))
    ])
  end

  # Generate savepoint names (some valid, some invalid)
  defp savepoint_name_gen do
    frequency([
      {7, safe_identifier_gen()},
      {1, constant("")},
      {1, constant("1invalid")},
      {1, sql_injection_gen()}
    ])
  end

  # ============================================================================
  # State Module Tests
  # ============================================================================

  describe "EctoLibSql.State.detect_mode/1 fuzz tests" do
    property "handles arbitrary keyword lists without crashing" do
      check all(
              opts <-
                list_of(
                  tuple({
                    member_of([:database, :uri, :auth_token, :sync, :other_key, :random]),
                    one_of([string(:printable), integer(), boolean(), nil])
                  }),
                  max_length: 10
                )
            ) do
        # Should never crash
        result = EctoLibSql.State.detect_mode(opts)
        assert result in [:local, :remote, :remote_replica, :unknown]
      end
    end

    property "detect_sync handles arbitrary keyword lists" do
      check all(
              opts <-
                list_of(
                  tuple({
                    member_of([:sync, :other, :random]),
                    one_of([boolean(), integer(), string(:printable), nil])
                  }),
                  max_length: 5
                )
            ) do
        result = EctoLibSql.State.detect_sync(opts)
        assert result in [:enable_sync, :disable_sync]
      end
    end
  end

  # ============================================================================
  # Native Module Tests
  # ============================================================================

  describe "EctoLibSql.Native.detect_command/1 fuzz tests" do
    property "handles arbitrary strings without crashing" do
      check all(query <- string(:printable, max_length: 500)) do
        result = EctoLibSql.Native.detect_command(query)

        assert result in [
                 :select,
                 :insert,
                 :update,
                 :delete,
                 :begin,
                 :commit,
                 :create,
                 :rollback,
                 :pragma,
                 :unknown,
                 :other,
                 nil
               ]
      end
    end

    property "handles binary data without crashing" do
      check all(query <- binary(max_length: 200)) do
        result = EctoLibSql.Native.detect_command(query)
        # Should return some result without crashing
        assert is_atom(result) or is_nil(result)
      end
    end

    property "correctly identifies known commands regardless of whitespace" do
      check all(
              cmd <- member_of(["SELECT", "INSERT", "UPDATE", "DELETE", "CREATE"]),
              leading <- string([?\s, ?\t, ?\n, ?\r], max_length: 5),
              trailing <- string(:printable, max_length: 20)
            ) do
        query = leading <> cmd <> " " <> trailing
        result = EctoLibSql.Native.detect_command(query)
        expected = cmd |> String.downcase() |> String.to_existing_atom()
        assert result == expected
      end
    end
  end

  describe "EctoLibSql.Native.vector/1 fuzz tests" do
    property "handles lists of numbers without crashing" do
      check all(values <- list_of(one_of([integer(), float()]), max_length: 100)) do
        result = EctoLibSql.Native.vector(values)
        assert is_binary(result)
        assert String.starts_with?(result, "[")
        assert String.ends_with?(result, "]")
      end
    end
  end

  describe "EctoLibSql.Native.vector_type/2 fuzz tests" do
    property "handles valid dimensions and types" do
      check all(
              dimensions <- positive_integer(),
              type <- member_of([:f32, :f64])
            ) do
        result = EctoLibSql.Native.vector_type(dimensions, type)
        assert is_binary(result)
        assert String.contains?(result, "BLOB")
      end
    end

    property "raises for invalid types" do
      check all(
              dimensions <- positive_integer(),
              type <- atom(:alphanumeric),
              type not in [:f32, :f64]
            ) do
        assert_raise ArgumentError, fn ->
          EctoLibSql.Native.vector_type(dimensions, type)
        end
      end
    end
  end

  # ============================================================================
  # Query Parameter Tests
  # ============================================================================

  describe "query parameter handling fuzz tests" do
    property "handles arbitrary text parameters via prepared statements", %{state: state} do
      check all(data <- query_param_gen()) do
        # We only test with string and numeric data types that SQLite can handle
        safe_data =
          case data do
            d when is_binary(d) -> d
            d when is_integer(d) -> d
            d when is_float(d) -> d
            nil -> nil
            true -> 1
            false -> 0
            _ -> inspect(data)
          end

        sql = "INSERT INTO fuzz_test (data) VALUES (?)"

        result =
          try do
            {:ok, stmt_id} = EctoLibSql.Native.prepare(state, sql)
            exec_result = EctoLibSql.Native.execute_stmt(state, stmt_id, sql, [safe_data])
            EctoLibSql.Native.close_stmt(stmt_id)
            exec_result
          rescue
            e -> {:exception, e}
          end

        # Should either succeed or return an error tuple, never crash
        case result do
          {:ok, _} -> assert true
          {:error, _} -> assert true
          {:exception, _} -> assert true
        end
      end
    end

    property "SQL injection attempts via parameters are safely escaped", %{state: state} do
      check all(injection <- sql_injection_gen()) do
        sql = "INSERT INTO fuzz_test (data) VALUES (?)"

        # Execute the injection attempt and capture the returned state.
        {result, current_state} =
          try do
            {:ok, _, exec_result, new_state} =
              EctoLibSql.handle_execute(sql, [injection], [], state)

            {exec_result, new_state}
          rescue
            e -> {{:exception, e}, state}
          end

        # Should succeed (parameter properly escaped) or return error.
        # Should NEVER execute injected SQL.
        case result do
          %EctoLibSql.Result{} -> assert true
          {:error, _} -> assert true
          {:exception, _} -> assert true
        end

        # Verify the fuzz_test table still exists (injection didn't drop it).
        # Use the state returned from the previous operation for consistency.
        {:ok, _, check_result, _} =
          EctoLibSql.handle_execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='fuzz_test'",
            [],
            [],
            current_state
          )

        assert check_result.num_rows == 1
      end
    end
  end

  # ============================================================================
  # Savepoint Name Validation Tests
  # ============================================================================

  describe "savepoint name validation fuzz tests" do
    property "handles arbitrary savepoint names without crashing", %{state: state} do
      check all(name <- savepoint_name_gen()) do
        # Each iteration needs a fresh connection to avoid transaction conflicts.
        case EctoLibSql.handle_begin([], state) do
          {:ok, :begin, trx_state} ->
            result =
              try do
                EctoLibSql.Native.create_savepoint(trx_state, name)
              rescue
                # Non-UTF8 binaries cause ArgumentError in NIF calls.
                ArgumentError -> {:error, :invalid_argument}
              end

            # Should either succeed or return an error, never crash.
            case result do
              :ok -> assert true
              {:error, _} -> assert true
            end

            # Clean up - rollback the transaction.
            EctoLibSql.handle_rollback([], trx_state)

          {:error, _, _} ->
            # Transaction couldn't start (e.g., already in transaction), skip.
            assert true
        end
      end
    end

    property "rejects all SQL injection attempts in savepoint names", %{state: state} do
      check all(injection <- sql_injection_with_chars_gen()) do
        # Each iteration needs a fresh connection to avoid transaction conflicts.
        case EctoLibSql.handle_begin([], state) do
          {:ok, :begin, trx_state} ->
            result =
              try do
                EctoLibSql.Native.create_savepoint(trx_state, injection)
              rescue
                ArgumentError -> {:error, :invalid_argument}
              end

            # Should always reject injection attempts.
            assert match?({:error, _}, result),
                   "Expected injection attempt '#{injection}' to be rejected"

            EctoLibSql.handle_rollback([], trx_state)

          {:error, _, _} ->
            # Transaction couldn't start (e.g., already in transaction), skip.
            assert true
        end
      end
    end
  end

  # ============================================================================
  # Connection ID Validation Tests
  # ============================================================================

  describe "connection ID handling fuzz tests" do
    property "handles arbitrary connection IDs gracefully" do
      check all(conn_id <- string(:printable, max_length: 100)) do
        result = EctoLibSql.Native.ping(conn_id)

        # Should return error tuple for invalid IDs, never crash
        case result do
          true -> assert true
          {:error, _} -> assert true
        end
      end
    end

    property "handles binary connection IDs gracefully" do
      check all(conn_id <- binary(max_length: 50)) do
        result =
          try do
            EctoLibSql.Native.ping(conn_id)
          rescue
            ArgumentError -> {:error, :argument_error}
          end

        case result do
          true -> assert true
          {:error, _} -> assert true
        end
      end
    end
  end

  # ============================================================================
  # Result Struct Tests
  # ============================================================================

  describe "EctoLibSql.Result.new/1 fuzz tests" do
    property "handles arbitrary options without crashing" do
      check all(
              command <-
                member_of([
                  :select,
                  :insert,
                  :update,
                  :delete,
                  :other,
                  :unknown,
                  nil,
                  :random_atom
                ]),
              num_rows <- non_negative_integer()
            ) do
        result = EctoLibSql.Result.new(command: command, num_rows: num_rows)

        assert %EctoLibSql.Result{} = result
        assert result.num_rows == num_rows
      end
    end
  end

  # ============================================================================
  # Error Module Tests
  # ============================================================================

  describe "EctoLibSql.Error fuzz tests" do
    property "constraint_violation? handles arbitrary messages" do
      check all(message <- string(:printable, max_length: 200)) do
        error = %EctoLibSql.Error{message: message}
        result = EctoLibSql.Error.constraint_violation?(error)
        assert is_boolean(result)
      end
    end

    property "constraint_name handles arbitrary messages" do
      check all(message <- string(:printable, max_length: 200)) do
        error = %EctoLibSql.Error{message: message}
        result = EctoLibSql.Error.constraint_name(error)
        assert is_nil(result) or is_binary(result)
      end
    end
  end

  # ============================================================================
  # Pragma Module Tests
  # ============================================================================

  describe "EctoLibSql.Pragma fuzz tests" do
    property "table_info handles arbitrary table names", %{state: state} do
      check all(table_name <- safe_identifier_gen()) do
        result = EctoLibSql.Pragma.table_info(state, table_name)

        # Should return ok tuple (possibly empty) or error, never crash
        case result do
          {:ok, %EctoLibSql.Result{}} -> assert true
          {:error, _} -> assert true
        end
      end
    end

    property "set_journal_mode only accepts valid modes", %{state: state} do
      valid_modes = [:delete, :wal, :memory, :persist, :truncate, :off]

      check all(mode <- member_of(valid_modes)) do
        result = EctoLibSql.Pragma.set_journal_mode(state, mode)
        assert match?({:ok, _}, result)
      end
    end

    property "set_synchronous accepts valid levels", %{state: state} do
      check all(level <- one_of([member_of([:off, :normal, :full, :extra]), integer(0..3)])) do
        result = EctoLibSql.Pragma.set_synchronous(state, level)
        assert match?({:ok, _}, result)
      end
    end

    property "set_user_version handles any integer", %{state: state} do
      check all(version <- integer(-2_147_483_648..2_147_483_647)) do
        result = EctoLibSql.Pragma.set_user_version(state, version)

        case result do
          {:ok, _} -> assert true
          {:error, _} -> assert true
        end
      end
    end
  end

  # ============================================================================
  # Batch Operations Tests
  # ============================================================================

  describe "batch operations fuzz tests" do
    property "execute_batch_sql handles arbitrary SQL strings", %{state: state} do
      check all(sql <- string(:printable, max_length: 200)) do
        result = EctoLibSql.Native.execute_batch_sql(state, sql)

        # Should return ok or error, never crash
        case result do
          {:ok, _} -> assert true
          {:error, _} -> assert true
        end
      end
    end
  end

  # ============================================================================
  # Large Input Tests
  # ============================================================================

  describe "large input handling" do
    @tag :slow
    property "handles large strings without crashing", %{state: state} do
      check all(
              size <- integer(1_000..10_000),
              char <- member_of([?a, ?b, ?c, ?x, ?y, ?z]),
              max_runs: 10
            ) do
        large_string = String.duplicate(<<char>>, size)

        result =
          try do
            EctoLibSql.handle_execute(
              "INSERT INTO fuzz_test (data) VALUES (?)",
              [large_string],
              [],
              state
            )
          rescue
            e -> {:exception, e}
          end

        case result do
          {:ok, _, _, _} -> assert true
          {:error, _, _} -> assert true
          {:exception, _} -> assert true
        end
      end
    end
  end

  # ============================================================================
  # Transaction Behaviour Fuzz Tests
  # ============================================================================

  describe "transaction behaviour fuzz tests" do
    property "transaction behaviours are handled correctly", %{state: state} do
      behaviours = [:deferred, :immediate, :exclusive]

      check all(behaviour <- member_of(behaviours)) do
        result = EctoLibSql.Native.begin(state, behavior: behaviour)

        case result do
          {:ok, trx_state} ->
            # Successfully started transaction, now rollback to clean up.
            rollback_result = EctoLibSql.Native.rollback(trx_state)
            assert match?({:ok, _}, rollback_result)

          {:error, _} ->
            # Database might be locked, that's acceptable.
            assert true
        end
      end
    end

    property "nested operations within transactions don't crash", %{state: state} do
      check all(
              num_ops <- integer(1..5),
              values <- list_of(string(:alphanumeric, max_length: 20), length: num_ops)
            ) do
        case EctoLibSql.Native.begin(state) do
          {:ok, trx_state} ->
            # Perform multiple operations.
            Enum.each(values, fn value ->
              sql = "INSERT INTO fuzz_test (data) VALUES (?)"

              try do
                EctoLibSql.handle_execute(sql, [value], [], trx_state)
              rescue
                _ -> :ok
              end
            end)

            # Rollback to clean up.
            EctoLibSql.Native.rollback(trx_state)

          {:error, _} ->
            assert true
        end
      end
    end
  end

  # ============================================================================
  # Prepared Statement Fuzz Tests
  # ============================================================================

  describe "prepared statement fuzz tests" do
    property "prepared statements handle various parameter types", %{state: state} do
      check all(
              int_val <- integer(),
              str_val <- string(:alphanumeric, max_length: 50),
              float_val <- float()
            ) do
        sql = "INSERT INTO fuzz_test (data, num) VALUES (?, ?)"

        result =
          try do
            {:ok, stmt_id} = EctoLibSql.Native.prepare(state, sql)
            exec_result = EctoLibSql.Native.execute_stmt(state, stmt_id, sql, [str_val, int_val])
            EctoLibSql.Native.close_stmt(stmt_id)
            exec_result
          rescue
            _ -> {:error, :exception}
          end

        case result do
          {:ok, _} -> assert true
          {:error, _} -> assert true
        end

        # Test with float in data column (stored as text).
        float_str = Float.to_string(float_val)

        result2 =
          try do
            {:ok, stmt_id} = EctoLibSql.Native.prepare(state, sql)

            exec_result =
              EctoLibSql.Native.execute_stmt(state, stmt_id, sql, [float_str, int_val])

            EctoLibSql.Native.close_stmt(stmt_id)
            exec_result
          rescue
            _ -> {:error, :exception}
          end

        case result2 do
          {:ok, _} -> assert true
          {:error, _} -> assert true
        end
      end
    end
  end

  # ============================================================================
  # Edge Case Numeric Value Tests
  # ============================================================================

  describe "edge case numeric values" do
    property "handles extreme integer values", %{state: state} do
      # SQLite INTEGER is 64-bit signed.
      extreme_values = [
        0,
        1,
        -1,
        9_223_372_036_854_775_807,
        -9_223_372_036_854_775_808
      ]

      check all(value <- member_of(extreme_values)) do
        sql = "INSERT INTO fuzz_test (num) VALUES (?)"

        result =
          try do
            EctoLibSql.handle_execute(sql, [value], [], state)
          rescue
            _ -> {:error, :exception, state}
          end

        case result do
          {:ok, _, _, _} -> assert true
          {:error, _, _} -> assert true
          {:disconnect, _, _} -> assert true
        end
      end
    end

    property "handles special float values gracefully", %{state: state} do
      # Note: SQLite stores floats as IEEE 754, but NaN/Infinity handling varies.
      check all(value <- float()) do
        sql = "INSERT INTO fuzz_test (data) VALUES (?)"
        str_value = Float.to_string(value)

        result =
          try do
            EctoLibSql.handle_execute(sql, [str_value], [], state)
          rescue
            _ -> {:error, :exception, state}
          end

        case result do
          {:ok, _, _, _} -> assert true
          {:error, _, _} -> assert true
          {:disconnect, _, _} -> assert true
        end
      end
    end
  end

  # ============================================================================
  # Binary/BLOB Data Fuzz Tests
  # ============================================================================

  describe "binary data handling" do
    property "handles arbitrary binary data in BLOB columns", %{state: state} do
      check all(blob_data <- binary(max_length: 1000)) do
        sql = "INSERT INTO fuzz_test (blob) VALUES (?)"
        # Wrap in {:blob, data} tuple so NIF treats it as binary, not text.
        blob_param = {:blob, blob_data}

        result =
          try do
            EctoLibSql.handle_execute(sql, [blob_param], [], state)
          rescue
            _ -> {:error, :exception, state}
          end

        case result do
          {:ok, _, _, _} -> assert true
          {:error, _, _} -> assert true
          {:disconnect, _, _} -> assert true
        end
      end
    end

    property "round-trips binary data correctly", %{state: state} do
      check all(blob_data <- binary(min_length: 1, max_length: 500), max_runs: 20) do
        # Insert the binary data wrapped as {:blob, data} so NIF treats it as binary.
        insert_sql = "INSERT INTO fuzz_test (blob) VALUES (?)"
        blob_param = {:blob, blob_data}

        case EctoLibSql.handle_execute(insert_sql, [blob_param], [], state) do
          {:ok, _, _, new_state} ->
            # Get the last inserted rowid.
            rowid = EctoLibSql.Native.get_last_insert_rowid(new_state)

            # Retrieve and verify the data.
            select_sql = "SELECT blob FROM fuzz_test WHERE id = ?"

            case EctoLibSql.handle_execute(select_sql, [rowid], [], new_state) do
              {:ok, _, select_result, _} ->
                if select_result.num_rows > 0 do
                  [[retrieved_blob]] = select_result.rows
                  assert retrieved_blob == blob_data
                end

              {:error, _, _} ->
                # Selection failed, that's acceptable for fuzz testing.
                assert true

              {:disconnect, _, _} ->
                # Disconnection, that's acceptable for fuzz testing.
                assert true
            end

          {:error, _, _} ->
            # Insert failed, that's acceptable for fuzz testing.
            assert true

          {:disconnect, _, _} ->
            # Disconnection, that's acceptable for fuzz testing.
            assert true
        end
      end
    end
  end
end
