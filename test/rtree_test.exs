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
    # Clean up any existing test database
    File.rm(@test_db)

    # Start the test repo
    {:ok, _} = TestRepo.start_link(database: @test_db)

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
  end

  describe "R*Tree queries" do
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

      assert result.rows == [[-34.1, -33.7]]
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
end
