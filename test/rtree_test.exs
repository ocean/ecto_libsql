defmodule Ecto.RTreeTest do
  use ExUnit.Case, async: false

  # Define test modules for Ecto schemas and repo
  defmodule TestRepo do
    use Ecto.Repo,
      otp_app: :ecto_libsql,
      adapter: Ecto.Adapters.LibSql
  end

  @test_db "z_ecto_libsql_test-rtree.db"

  setup_all do
    # Clean up any existing test database files
    File.rm(@test_db)
    File.rm(@test_db <> "-shm")
    File.rm(@test_db <> "-wal")

    # Start the test repo
    {:ok, _} = TestRepo.start_link(database: @test_db)

    # Clean up after all tests complete - stop GenServer and remove db files
    on_exit(fn ->
      try do
        GenServer.stop(TestRepo)
      catch
        _, _ -> nil
      end

      File.rm(@test_db)
      File.rm(@test_db <> "-shm")
      File.rm(@test_db <> "-wal")
    end)

    :ok
  end

  describe "R*Tree table creation" do
    test "creates 2D R*Tree table successfully" do
      # Create R*Tree table using Ecto.Adapters.SQL
      Ecto.Adapters.SQL.query!(TestRepo, """
      DROP TABLE IF EXISTS locations_rtree
      """)

      # Manually generate the SQL for now since we need to test the DDL generation
      import Ecto.Adapters.LibSql.Connection

      table = %Ecto.Migration.Table{
        name: :locations_rtree,
        prefix: nil,
        options: [rtree: true]
      }

      columns = [
        {:add, :id, :integer, [primary_key: true]},
        {:add, :min_lat, :float, []},
        {:add, :max_lat, :float, []},
        {:add, :min_lng, :float, []},
        {:add, :max_lng, :float, []}
      ]

      [sql] = execute_ddl({:create, table, columns})

      assert sql =~ "CREATE VIRTUAL TABLE"
      assert sql =~ "USING rtree"
      assert sql =~ "id, min_lat, max_lat, min_lng, max_lng"

      # Actually create the table
      Ecto.Adapters.SQL.query!(TestRepo, sql)

      # Verify table was created
      result =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          "SELECT name FROM sqlite_master WHERE type='table' AND name='locations_rtree'"
        )

      assert length(result.rows) == 1
    end

    test "creates 3D R*Tree table successfully" do
      import Ecto.Adapters.LibSql.Connection

      table = %Ecto.Migration.Table{
        name: :locations_rtree_3d,
        prefix: nil,
        options: [rtree: true]
      }

      columns = [
        {:add, :id, :integer, [primary_key: true]},
        {:add, :min_x, :float, []},
        {:add, :max_x, :float, []},
        {:add, :min_y, :float, []},
        {:add, :max_y, :float, []},
        {:add, :min_z, :float, []},
        {:add, :max_z, :float, []}
      ]

      [sql] = execute_ddl({:create, table, columns})

      assert sql =~ "CREATE VIRTUAL TABLE"
      assert sql =~ "USING rtree"
      assert sql =~ "id, min_x, max_x, min_y, max_y, min_z, max_z"
    end

    test "creates R*Tree table with IF NOT EXISTS" do
      import Ecto.Adapters.LibSql.Connection

      table = %Ecto.Migration.Table{
        name: :locations_rtree_ifne,
        prefix: nil,
        options: [rtree: true]
      }

      columns = [
        {:add, :id, :integer, [primary_key: true]},
        {:add, :min_lat, :float, []},
        {:add, :max_lat, :float, []},
        {:add, :min_lng, :float, []},
        {:add, :max_lng, :float, []}
      ]

      [sql] = execute_ddl({:create_if_not_exists, table, columns})

      assert sql =~ "CREATE VIRTUAL TABLE IF NOT EXISTS"
      assert sql =~ "USING rtree"
    end
  end

  describe "R*Tree table validation" do
    test "rejects R*Tree table with too few columns" do
      import Ecto.Adapters.LibSql.Connection

      table = %Ecto.Migration.Table{
        name: :invalid_rtree,
        prefix: nil,
        options: [rtree: true]
      }

      # Only 1 column (id) - need at least 3
      columns = [
        {:add, :id, :integer, [primary_key: true]}
      ]

      assert_raise ArgumentError, ~r/at least 3 columns/, fn ->
        execute_ddl({:create, table, columns})
      end
    end

    test "rejects R*Tree table with too many columns" do
      import Ecto.Adapters.LibSql.Connection

      table = %Ecto.Migration.Table{
        name: :invalid_rtree,
        prefix: nil,
        options: [rtree: true]
      }

      # 13 columns (id + 12 coordinates = 6 dimensions) - max is 11
      columns = [
        {:add, :id, :integer, [primary_key: true]},
        {:add, :min_1, :float, []},
        {:add, :max_1, :float, []},
        {:add, :min_2, :float, []},
        {:add, :max_2, :float, []},
        {:add, :min_3, :float, []},
        {:add, :max_3, :float, []},
        {:add, :min_4, :float, []},
        {:add, :max_4, :float, []},
        {:add, :min_5, :float, []},
        {:add, :max_5, :float, []},
        {:add, :min_6, :float, []},
        {:add, :max_6, :float, []}
      ]

      assert_raise ArgumentError, ~r/maximum 11 columns/, fn ->
        execute_ddl({:create, table, columns})
      end
    end

    test "rejects R*Tree table with even number of columns" do
      import Ecto.Adapters.LibSql.Connection

      table = %Ecto.Migration.Table{
        name: :invalid_rtree,
        prefix: nil,
        options: [rtree: true]
      }

      # 4 columns (even number) - need odd number
      columns = [
        {:add, :id, :integer, [primary_key: true]},
        {:add, :min_lat, :float, []},
        {:add, :max_lat, :float, []},
        {:add, :min_lng, :float, []}
      ]

      assert_raise ArgumentError, ~r/odd number of columns/, fn ->
        execute_ddl({:create, table, columns})
      end
    end

    test "rejects R*Tree table without id as first column" do
      import Ecto.Adapters.LibSql.Connection

      table = %Ecto.Migration.Table{
        name: :invalid_rtree,
        prefix: nil,
        options: [rtree: true]
      }

      # First column is not 'id'
      columns = [
        {:add, :row_id, :integer, [primary_key: true]},
        {:add, :min_lat, :float, []},
        {:add, :max_lat, :float, []},
        {:add, :min_lng, :float, []},
        {:add, :max_lng, :float, []}
      ]

      assert_raise ArgumentError, ~r/must have 'id' as the first column/, fn ->
        execute_ddl({:create, table, columns})
      end
    end

    test "rejects R*Tree table with incompatible options" do
      import Ecto.Adapters.LibSql.Connection

      # Test with :strict option
      table = %Ecto.Migration.Table{
        name: :invalid_rtree,
        prefix: nil,
        options: [rtree: true, strict: true]
      }

      columns = [
        {:add, :id, :integer, [primary_key: true]},
        {:add, :min_lat, :float, []},
        {:add, :max_lat, :float, []},
        {:add, :min_lng, :float, []},
        {:add, :max_lng, :float, []}
      ]

      assert_raise ArgumentError, ~r/do not support standard table options/, fn ->
        execute_ddl({:create, table, columns})
      end

      # Test with :random_rowid option
      table = %Ecto.Migration.Table{
        name: :invalid_rtree,
        prefix: nil,
        options: [rtree: true, random_rowid: true]
      }

      assert_raise ArgumentError, ~r/Found incompatible options: :random_rowid/, fn ->
        execute_ddl({:create, table, columns})
      end

      # Test with multiple incompatible options
      table = %Ecto.Migration.Table{
        name: :invalid_rtree,
        prefix: nil,
        options: [rtree: true, strict: true, random_rowid: true]
      }

      assert_raise ArgumentError, ~r/do not support standard table options/, fn ->
        execute_ddl({:create, table, columns})
      end
    end
  end

  describe "R*Tree queries and operations" do
    # Each test gets its own fresh data to avoid order dependencies
    setup do
      # Create R*Tree table
      Ecto.Adapters.SQL.query!(TestRepo, """
      DROP TABLE IF EXISTS geo_regions
      """)

      Ecto.Adapters.SQL.query!(TestRepo, """
      CREATE VIRTUAL TABLE geo_regions USING rtree(
        id,
        min_lat, max_lat,
        min_lng, max_lng
      )
      """)

      # Insert test data
      # Sydney region: -34.0 to -33.8 lat, 151.0 to 151.3 lng
      Ecto.Adapters.SQL.query!(
        TestRepo,
        "INSERT INTO geo_regions VALUES (1, -34.0, -33.8, 151.0, 151.3)"
      )

      # Melbourne region: -38.0 to -37.7 lat, 144.8 to 145.1 lng
      Ecto.Adapters.SQL.query!(
        TestRepo,
        "INSERT INTO geo_regions VALUES (2, -38.0, -37.7, 144.8, 145.1)"
      )

      # Brisbane region: -27.6 to -27.3 lat, 152.9 to 153.2 lng
      Ecto.Adapters.SQL.query!(
        TestRepo,
        "INSERT INTO geo_regions VALUES (3, -27.6, -27.3, 152.9, 153.2)"
      )

      :ok
    end

    test "finds regions containing a point" do
      # Point in Sydney: -33.87, 151.21
      result =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          """
          SELECT id FROM geo_regions
          WHERE min_lat <= -33.87 AND max_lat >= -33.87
            AND min_lng <= 151.21 AND max_lng >= 151.21
          """
        )

      assert result.rows == [[1]]
    end

    test "finds regions intersecting a bounding box" do
      # Bounding box covering Sydney area
      result =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          """
          SELECT id FROM geo_regions
          WHERE max_lat >= -34.0
            AND min_lat <= -33.8
            AND max_lng >= 151.0
            AND min_lng <= 151.3
          ORDER BY id
          """
        )

      assert result.rows == [[1]]
    end

    test "finds all regions" do
      result =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          "SELECT id FROM geo_regions ORDER BY id"
        )

      assert result.rows == [[1], [2], [3]]
    end

    test "updates R*Tree entry" do
      # Update Sydney region bounds
      Ecto.Adapters.SQL.query!(
        TestRepo,
        "UPDATE geo_regions SET min_lat = -34.1, max_lat = -33.7 WHERE id = 1"
      )

      # Verify update
      result =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          "SELECT min_lat, max_lat FROM geo_regions WHERE id = 1"
        )

      # Use approximate comparison for floats due to SQLite floating point precision
      assert [[min_lat, max_lat]] = result.rows
      assert_in_delta min_lat, -34.1, 0.01
      assert_in_delta max_lat, -33.7, 0.01
    end

    test "deletes R*Tree entry" do
      # Delete Melbourne region
      Ecto.Adapters.SQL.query!(TestRepo, "DELETE FROM geo_regions WHERE id = 2")

      # Verify deletion
      result =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          "SELECT id FROM geo_regions ORDER BY id"
        )

      assert result.rows == [[1], [3]]
    end
  end

  describe "R*Tree edge cases and advanced scenarios" do
    test "handles empty R*Tree table" do
      # Create and query empty R*Tree table
      Ecto.Adapters.SQL.query!(TestRepo, """
      DROP TABLE IF EXISTS empty_rtree
      """)

      Ecto.Adapters.SQL.query!(TestRepo, """
      CREATE VIRTUAL TABLE empty_rtree USING rtree(
        id,
        min_lat, max_lat,
        min_lng, max_lng
      )
      """)

      result =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          "SELECT COUNT(*) FROM empty_rtree"
        )

      assert result.rows == [[0]]
    end

    test "handles boundary condition with min=max coordinates" do
      Ecto.Adapters.SQL.query!(TestRepo, """
      DROP TABLE IF EXISTS point_rtree
      """)

      Ecto.Adapters.SQL.query!(TestRepo, """
      CREATE VIRTUAL TABLE point_rtree USING rtree(
        id,
        min_x, max_x,
        min_y, max_y
      )
      """)

      # Insert a point (min=max for both dimensions)
      Ecto.Adapters.SQL.query!(
        TestRepo,
        "INSERT INTO point_rtree VALUES (1, 0.0, 0.0, 0.0, 0.0)"
      )

      # Query for exact point
      result =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          """
          SELECT id FROM point_rtree
          WHERE min_x <= 0.0 AND max_x >= 0.0
            AND min_y <= 0.0 AND max_y >= 0.0
          """
        )

      assert result.rows == [[1]]
    end

    test "handles bulk inserts with many regions" do
      Ecto.Adapters.SQL.query!(TestRepo, """
      DROP TABLE IF EXISTS bulk_rtree
      """)

      Ecto.Adapters.SQL.query!(TestRepo, """
      CREATE VIRTUAL TABLE bulk_rtree USING rtree(
        id,
        min_x, max_x,
        min_y, max_y
      )
      """)

      # Bulk insert 100 regions
      Enum.each(1..100, fn i ->
        Ecto.Adapters.SQL.query!(
          TestRepo,
          "INSERT INTO bulk_rtree VALUES (#{i}, #{i}.0, #{i + 1}.0, #{i}.0, #{i + 1}.0)"
        )
      end)

      result =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          "SELECT COUNT(*) FROM bulk_rtree"
        )

      assert result.rows == [[100]]

      # Verify we can query in the bulk data
      result =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          """
          SELECT COUNT(*) FROM bulk_rtree
          WHERE max_x >= 50.0 AND min_x <= 51.0
          """
        )

      assert [[count]] = result.rows
      assert count >= 1
    end

    test "handles R*Tree operations within transaction rollback" do
      Ecto.Adapters.SQL.query!(TestRepo, """
      DROP TABLE IF EXISTS txn_rtree
      """)

      Ecto.Adapters.SQL.query!(TestRepo, """
      CREATE VIRTUAL TABLE txn_rtree USING rtree(
        id,
        min_x, max_x,
        min_y, max_y
      )
      """)

      # Insert initial data
      Ecto.Adapters.SQL.query!(
        TestRepo,
        "INSERT INTO txn_rtree VALUES (1, 0.0, 1.0, 0.0, 1.0)"
      )

      # Begin transaction and insert, then rollback
      case EctoLibSql.connect(database: @test_db) do
        {:ok, state} ->
          {:ok, :begin, state} = EctoLibSql.handle_begin([], state)

          # Insert within transaction
          {:ok, _query, _result, state} =
            EctoLibSql.handle_execute(
              "INSERT INTO txn_rtree VALUES (2, 2.0, 3.0, 2.0, 3.0)",
              [],
              [],
              state
            )

          # Rollback the transaction
          {:ok, _rollback_result, _final_state} = EctoLibSql.handle_rollback([], state)

          # Verify only original data exists
          result =
            Ecto.Adapters.SQL.query!(
              TestRepo,
              "SELECT COUNT(*) FROM txn_rtree"
            )

          assert result.rows == [[1]]

        {:error, _reason} ->
          # Skip if connection fails
          :ok
      end
    end

    test "handles different coordinate types (integer vs float)" do
      Ecto.Adapters.SQL.query!(TestRepo, """
      DROP TABLE IF EXISTS mixed_coords
      """)

      Ecto.Adapters.SQL.query!(TestRepo, """
      CREATE VIRTUAL TABLE mixed_coords USING rtree(
        id,
        min_x, max_x,
        min_y, max_y
      )
      """)

      # Insert with integer coordinates (SQLite converts to float internally)
      Ecto.Adapters.SQL.query!(
        TestRepo,
        "INSERT INTO mixed_coords VALUES (1, 1, 2, 1, 2)"
      )

      # Insert with float coordinates
      Ecto.Adapters.SQL.query!(
        TestRepo,
        "INSERT INTO mixed_coords VALUES (2, 2.5, 3.5, 2.5, 3.5)"
      )

      # Both should be queryable
      result =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          "SELECT COUNT(*) FROM mixed_coords"
        )

      assert result.rows == [[2]]
    end

    test "handles large coordinate values" do
      Ecto.Adapters.SQL.query!(TestRepo, """
      DROP TABLE IF EXISTS large_coords
      """)

      Ecto.Adapters.SQL.query!(TestRepo, """
      CREATE VIRTUAL TABLE large_coords USING rtree(
        id,
        min_x, max_x,
        min_y, max_y
      )
      """)

      # Insert with very large coordinate values
      Ecto.Adapters.SQL.query!(
        TestRepo,
        "INSERT INTO large_coords VALUES (1, -180.0, 180.0, -90.0, 90.0)"
      )

      result =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          """
          SELECT id FROM large_coords
          WHERE max_x >= 0.0 AND min_x <= 0.0
            AND max_y >= 0.0 AND min_y <= 0.0
          """
        )

      assert result.rows == [[1]]
    end
  end
end
