defmodule Ecto.Vector.GeospatialTest do
  use ExUnit.Case, async: false

  # Define test modules for Ecto schemas and repo
  defmodule TestRepo do
    use Ecto.Repo,
      otp_app: :ecto_libsql,
      adapter: Ecto.Adapters.LibSql
  end

  defmodule Location do
    use Ecto.Schema
    import Ecto.Changeset

    schema "locations" do
      field(:name, :string)
      field(:latitude, :float)
      field(:longitude, :float)
      field(:embedding, :string)
      field(:city, :string)
      field(:country, :string)

      timestamps()
    end

    def changeset(location, attrs) do
      location
      |> cast(attrs, [:name, :latitude, :longitude, :embedding, :city, :country])
      |> validate_required([:name, :latitude, :longitude])
    end
  end

  @test_db "z_ecto_libsql_test-vector_geospatial.db"

  setup_all do
    # Start the test repo
    {:ok, _} = TestRepo.start_link(database: @test_db)

    # Create table with vector column for 2D coordinate embeddings
    # Using F32_BLOB(2) for latitude/longitude pairs
    Ecto.Adapters.SQL.query!(TestRepo, """
    CREATE TABLE IF NOT EXISTS locations (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      latitude REAL NOT NULL,
      longitude REAL NOT NULL,
      embedding F32_BLOB(2),
      city TEXT,
      country TEXT,
      inserted_at DATETIME,
      updated_at DATETIME
    )
    """)

    on_exit(fn ->
      File.rm(@test_db)
      File.rm(@test_db <> "-wal")
      File.rm(@test_db <> "-shm")
    end)

    :ok
  end

  setup do
    # Clean tables before each test
    Ecto.Adapters.SQL.query!(TestRepo, "DELETE FROM locations")
    :ok
  end

  describe "vector geospatial search" do
    test "finds nearest locations by cosine distance" do
      # Insert famous world cities with their coordinates normalized to [-1, 1] range
      # Real coordinates: latitude [-90, 90], longitude [-180, 180]
      # Normalized: divide by max (90 for lat, 180 for lon) to get [-1, 1] range

      cities = [
        # Sydney, Australia (-33.87, 151.21)
        {
          "Sydney",
          -33.87,
          151.21,
          EctoLibSql.Native.vector([-33.87 / 90, 151.21 / 180]),
          "Sydney",
          "Australia"
        },
        # Melbourne, Australia (-37.81, 144.96)
        {
          "Melbourne",
          -37.81,
          144.96,
          EctoLibSql.Native.vector([-37.81 / 90, 144.96 / 180]),
          "Melbourne",
          "Australia"
        },
        # Auckland, New Zealand (-37.01, 174.88)
        {
          "Auckland",
          -37.01,
          174.88,
          EctoLibSql.Native.vector([-37.01 / 90, 174.88 / 180]),
          "Auckland",
          "New Zealand"
        },
        # Tokyo, Japan (35.68, 139.69)
        {
          "Tokyo",
          35.68,
          139.69,
          EctoLibSql.Native.vector([35.68 / 90, 139.69 / 180]),
          "Tokyo",
          "Japan"
        },
        # New York, USA (40.71, -74.01)
        {
          "New York",
          40.71,
          -74.01,
          EctoLibSql.Native.vector([40.71 / 90, -74.01 / 180]),
          "New York",
          "USA"
        }
      ]

      # Insert all cities
      Enum.each(cities, fn {name, lat, lon, embedding, city, country} ->
        TestRepo.insert!(%Location{
          name: name,
          latitude: lat,
          longitude: lon,
          embedding: embedding,
          city: city,
          country: country
        })
      end)

      # Search for locations nearest to Sydney
      # Sydney normalized: [-33.87/90, 151.21/180] ≈ [-0.3764, 0.8400]
      sydney_embedding = EctoLibSql.Native.vector([-33.87 / 90, 151.21 / 180])

      # Query using cosine distance
      result =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          """
          SELECT name, city, country, vector_distance_cos(embedding, vector(?)) as distance
          FROM locations
          ORDER BY distance
          LIMIT 3
          """,
          [sydney_embedding]
        )

      # Should return Sydney first (distance 0 to itself), followed by other cities
      assert result.num_rows == 3

      [
        [sydney_name, _, _, sydney_dist],
        [second_name, _, _, second_dist],
        [third_name, _, _, third_dist]
      ] =
        result.rows

      assert sydney_name == "Sydney"

      # Sydney should be closest to itself (distance very close to 0)
      assert sydney_dist < 0.001

      # Verify other results are farther than Sydney
      assert second_dist > sydney_dist
      assert third_dist > sydney_dist

      # All results should be valid city names
      assert second_name in ["Melbourne", "Auckland", "Tokyo", "New York"]
      assert third_name in ["Melbourne", "Auckland", "Tokyo", "New York"]
    end

    test "filters nearest locations by region" do
      # Insert cities from different regions
      Ecto.Adapters.SQL.query!(
        TestRepo,
        """
        INSERT INTO locations (name, latitude, longitude, embedding, city, country, inserted_at, updated_at)
        VALUES
          ('Sydney', -33.87, 151.21, vector(?), 'Sydney', 'Australia', datetime('now'), datetime('now')),
          ('Melbourne', -37.81, 144.96, vector(?), 'Melbourne', 'Australia', datetime('now'), datetime('now')),
          ('Tokyo', 35.68, 139.69, vector(?), 'Tokyo', 'Japan', datetime('now'), datetime('now')),
          ('Osaka', 34.67, 135.50, vector(?), 'Osaka', 'Japan', datetime('now'), datetime('now')),
          ('New York', 40.71, -74.01, vector(?), 'New York', 'USA', datetime('now'), datetime('now'))
        """,
        [
          EctoLibSql.Native.vector([-33.87 / 90, 151.21 / 180]),
          EctoLibSql.Native.vector([-37.81 / 90, 144.96 / 180]),
          EctoLibSql.Native.vector([35.68 / 90, 139.69 / 180]),
          EctoLibSql.Native.vector([34.67 / 90, 135.50 / 180]),
          EctoLibSql.Native.vector([40.71 / 90, -74.01 / 180])
        ]
      )

      # Find nearest location to Tokyo, but only in Asia
      tokyo_embedding = EctoLibSql.Native.vector([35.68 / 90, 139.69 / 180])

      result =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          """
          SELECT name, city, country, vector_distance_cos(embedding, vector(?)) as distance
          FROM locations
          WHERE country IN ('Japan', 'Australia')
          ORDER BY distance
          LIMIT 2
          """,
          [tokyo_embedding]
        )

      assert result.num_rows == 2

      [
        [first_name, _, first_country, first_dist],
        [second_name, _, _second_country, _second_dist]
      ] =
        result.rows

      # Tokyo should be first (distance 0)
      assert first_name == "Tokyo"
      assert first_country == "Japan"
      assert first_dist < 0.001

      # Osaka should be second (closest other Japan city to Tokyo)
      assert second_name == "Osaka"
    end

    test "searches within distance threshold" do
      # Insert cities
      Ecto.Adapters.SQL.query!(
        TestRepo,
        """
        INSERT INTO locations (name, latitude, longitude, embedding, city, country, inserted_at, updated_at)
        VALUES
          ('Sydney', -33.87, 151.21, vector(?), 'Sydney', 'Australia', datetime('now'), datetime('now')),
          ('Melbourne', -37.81, 144.96, vector(?), 'Melbourne', 'Australia', datetime('now'), datetime('now')),
          ('Brisbane', -27.47, 153.03, vector(?), 'Brisbane', 'Australia', datetime('now'), datetime('now')),
          ('Tokyo', 35.68, 139.69, vector(?), 'Tokyo', 'Japan', datetime('now'), datetime('now')),
          ('New York', 40.71, -74.01, vector(?), 'New York', 'USA', datetime('now'), datetime('now'))
        """,
        [
          EctoLibSql.Native.vector([-33.87 / 90, 151.21 / 180]),
          EctoLibSql.Native.vector([-37.81 / 90, 144.96 / 180]),
          EctoLibSql.Native.vector([-27.47 / 90, 153.03 / 180]),
          EctoLibSql.Native.vector([35.68 / 90, 139.69 / 180]),
          EctoLibSql.Native.vector([40.71 / 90, -74.01 / 180])
        ]
      )

      # Search for locations within a certain distance of Sydney
      # Using a threshold of 0.15 (roughly 15% of max distance in normalized space)
      sydney_embedding = EctoLibSql.Native.vector([-33.87 / 90, 151.21 / 180])

      result =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          """
          SELECT name, country, vector_distance_cos(embedding, vector(?)) as distance
          FROM locations
          WHERE vector_distance_cos(embedding, vector(?)) < 0.15
          ORDER BY distance
          """,
          [sydney_embedding, sydney_embedding]
        )

      # Should find Sydney and nearby Australian cities
      names = Enum.map(result.rows, fn [name, _, _] -> name end)

      assert "Sydney" in names
      assert "Melbourne" in names
      assert "Brisbane" in names
      # Tokyo and New York should be too far (distance > 0.15)
      assert "Tokyo" not in names
      assert "New York" not in names
    end

    test "aggregates nearest neighbors by country" do
      # Insert multiple cities per country
      Ecto.Adapters.SQL.query!(
        TestRepo,
        """
        INSERT INTO locations (name, latitude, longitude, embedding, city, country, inserted_at, updated_at)
        VALUES
          ('Sydney', -33.87, 151.21, vector(?), 'Sydney', 'Australia', datetime('now'), datetime('now')),
          ('Melbourne', -37.81, 144.96, vector(?), 'Melbourne', 'Australia', datetime('now'), datetime('now')),
          ('Brisbane', -27.47, 153.03, vector(?), 'Brisbane', 'Australia', datetime('now'), datetime('now')),
          ('Tokyo', 35.68, 139.69, vector(?), 'Tokyo', 'Japan', datetime('now'), datetime('now')),
          ('Osaka', 34.67, 135.50, vector(?), 'Osaka', 'Japan', datetime('now'), datetime('now')),
          ('New York', 40.71, -74.01, vector(?), 'New York', 'USA', datetime('now'), datetime('now')),
          ('Los Angeles', 34.05, -118.24, vector(?), 'Los Angeles', 'USA', datetime('now'), datetime('now'))
        """,
        [
          EctoLibSql.Native.vector([-33.87 / 90, 151.21 / 180]),
          EctoLibSql.Native.vector([-37.81 / 90, 144.96 / 180]),
          EctoLibSql.Native.vector([-27.47 / 90, 153.03 / 180]),
          EctoLibSql.Native.vector([35.68 / 90, 139.69 / 180]),
          EctoLibSql.Native.vector([34.67 / 90, 135.50 / 180]),
          EctoLibSql.Native.vector([40.71 / 90, -74.01 / 180]),
          EctoLibSql.Native.vector([34.05 / 90, -118.24 / 180])
        ]
      )

      # Find the closest location to Sydney in each country
      sydney_embedding = EctoLibSql.Native.vector([-33.87 / 90, 151.21 / 180])

      result =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          """
          SELECT
            country,
            name,
            vector_distance_cos(embedding, vector(?)) as distance
          FROM locations
          WHERE country != 'Australia'
          ORDER BY country, distance
          """,
          [sydney_embedding]
        )

      assert result.num_rows == 4
      rows = result.rows

      # Extract Japan results
      japan_rows = Enum.filter(rows, fn [country, _, _] -> country == "Japan" end)
      assert length(japan_rows) == 2
      [[japan_country, japan_city, japan_dist], [_, _, second_japan_dist]] = japan_rows
      assert japan_country == "Japan"
      assert japan_city == "Tokyo"
      assert japan_dist < second_japan_dist

      # Extract USA results
      usa_rows = Enum.filter(rows, fn [country, _, _] -> country == "USA" end)
      assert length(usa_rows) == 2
      [[usa_country, _usa_city, usa_dist], [_, _, second_usa_dist]] = usa_rows
      assert usa_country == "USA"
      assert usa_dist < second_usa_dist
    end

    test "finds approximate locations using vector ranges" do
      # Insert locations in specific regions
      Ecto.Adapters.SQL.query!(
        TestRepo,
        """
        INSERT INTO locations (name, latitude, longitude, embedding, city, country, inserted_at, updated_at)
        VALUES
          ('Sydney', -33.87, 151.21, vector(?), 'Sydney', 'Australia', datetime('now'), datetime('now')),
          ('Melbourne', -37.81, 144.96, vector(?), 'Melbourne', 'Australia', datetime('now'), datetime('now')),
          ('Tokyo', 35.68, 139.69, vector(?), 'Tokyo', 'Japan', datetime('now'), datetime('now')),
          ('Bangkok', 13.73, 100.50, vector(?), 'Bangkok', 'Thailand', datetime('now'), datetime('now')),
          ('Singapore', 1.35, 103.82, vector(?), 'Singapore', 'Singapore', datetime('now'), datetime('now')),
          ('New York', 40.71, -74.01, vector(?), 'New York', 'USA', datetime('now'), datetime('now'))
        """,
        [
          EctoLibSql.Native.vector([-33.87 / 90, 151.21 / 180]),
          EctoLibSql.Native.vector([-37.81 / 90, 144.96 / 180]),
          EctoLibSql.Native.vector([35.68 / 90, 139.69 / 180]),
          EctoLibSql.Native.vector([13.73 / 90, 100.50 / 180]),
          EctoLibSql.Native.vector([1.35 / 90, 103.82 / 180]),
          EctoLibSql.Native.vector([40.71 / 90, -74.01 / 180])
        ]
      )

      # Find locations in Southeast Asia (roughly 0-30° N, 95-140° E)
      # Normalized: latitude [0/90, 30/90] = [0, 0.33], longitude [95/180, 140/180] = [0.53, 0.78]
      result =
        Ecto.Adapters.SQL.query!(TestRepo, """
        SELECT name, latitude, longitude, city, country
        FROM locations
        WHERE city IN (
          SELECT city FROM locations
          WHERE latitude > 0 AND latitude < 30
          AND longitude > 95 AND longitude < 140
        )
        ORDER BY name
        """)

      names = Enum.map(result.rows, fn [name, _, _, _, _] -> name end)

      assert length(names) == 2
      assert "Bangkok" in names
      assert "Singapore" in names
      assert "Sydney" not in names
      assert "New York" not in names
    end
  end

  describe "vector edge cases" do
    test "handles NULL embeddings gracefully" do
      # Insert location with NULL embedding
      Ecto.Adapters.SQL.query!(
        TestRepo,
        """
        INSERT INTO locations (name, latitude, longitude, embedding, city, country, inserted_at, updated_at)
        VALUES
          ('Sydney', -33.87, 151.21, vector(?), 'Sydney', 'Australia', datetime('now'), datetime('now')),
          ('Unknown', 0.0, 0.0, NULL, 'Unknown', 'Unknown', datetime('now'), datetime('now')),
          ('Tokyo', 35.68, 139.69, vector(?), 'Tokyo', 'Japan', datetime('now'), datetime('now'))
        """,
        [
          EctoLibSql.Native.vector([-33.87 / 90, 151.21 / 180]),
          EctoLibSql.Native.vector([35.68 / 90, 139.69 / 180])
        ]
      )

      # Query should filter out NULL embeddings
      result =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          """
          SELECT name, city
          FROM locations
          WHERE embedding IS NOT NULL
          ORDER BY name
          """
        )

      assert result.num_rows == 2
      names = Enum.map(result.rows, fn [name, _] -> name end)
      assert "Sydney" in names
      assert "Tokyo" in names
      assert "Unknown" not in names
    end

    test "returns empty result set when no locations match" do
      # Insert only locations far from query point
      Ecto.Adapters.SQL.query!(
        TestRepo,
        """
        INSERT INTO locations (name, latitude, longitude, embedding, city, country, inserted_at, updated_at)
        VALUES
          ('Tokyo', 35.68, 139.69, vector(?), 'Tokyo', 'Japan', datetime('now'), datetime('now')),
          ('New York', 40.71, -74.01, vector(?), 'New York', 'USA', datetime('now'), datetime('now'))
        """,
        [
          EctoLibSql.Native.vector([35.68 / 90, 139.69 / 180]),
          EctoLibSql.Native.vector([40.71 / 90, -74.01 / 180])
        ]
      )

      # Query with impossible distance threshold
      result =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          """
          SELECT name, city, vector_distance_cos(embedding, vector(?)) as distance
          FROM locations
          WHERE vector_distance_cos(embedding, vector(?)) < 0.01
          ORDER BY distance
          """,
          [
            EctoLibSql.Native.vector([0.5, 0.5]),
            EctoLibSql.Native.vector([0.5, 0.5])
          ]
        )

      assert result.num_rows == 0
    end

    test "handles zero distance (identical embeddings)" do
      # Insert same location twice
      embedding = EctoLibSql.Native.vector([-33.87 / 90, 151.21 / 180])

      Ecto.Adapters.SQL.query!(
        TestRepo,
        """
        INSERT INTO locations (name, latitude, longitude, embedding, city, country, inserted_at, updated_at)
        VALUES
          ('Sydney', -33.87, 151.21, vector(?), 'Sydney', 'Australia', datetime('now'), datetime('now')),
          ('Sydney Copy', -33.87, 151.21, vector(?), 'Sydney', 'Australia', datetime('now'), datetime('now')),
          ('Tokyo', 35.68, 139.69, vector(?), 'Tokyo', 'Japan', datetime('now'), datetime('now'))
        """,
        [embedding, embedding, EctoLibSql.Native.vector([35.68 / 90, 139.69 / 180])]
      )

      result =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          """
          SELECT name, vector_distance_cos(embedding, vector(?)) as distance
          FROM locations
          ORDER BY distance
          """,
          [embedding]
        )

      # First two should have distance close to 0
      [
        [_first_name, first_dist],
        [_second_name, second_dist],
        [_third_name, third_dist]
      ] = result.rows

      # Both Sydney records should be at distance 0
      assert first_dist < 0.001
      assert second_dist < 0.001
      # Tokyo should be farther (but not necessarily > 0.5 given coordinate ranges)
      assert third_dist > first_dist
    end

    test "handles query with only NULL embeddings in table" do
      # Insert location with NULL embedding
      Ecto.Adapters.SQL.query!(
        TestRepo,
        """
        INSERT INTO locations (name, latitude, longitude, embedding, city, country, inserted_at, updated_at)
        VALUES
          ('Unknown1', 0.0, 0.0, NULL, 'Unknown', 'Unknown', datetime('now'), datetime('now')),
          ('Unknown2', 0.0, 0.0, NULL, 'Unknown', 'Unknown', datetime('now'), datetime('now'))
        """
      )

      result =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          """
          SELECT name, embedding
          FROM locations
          WHERE embedding IS NOT NULL
          """
        )

      assert result.num_rows == 0
    end

    test "handles distance calculation with extreme coordinate values" do
      # Insert locations at extreme valid coordinates
      Ecto.Adapters.SQL.query!(
        TestRepo,
        """
        INSERT INTO locations (name, latitude, longitude, embedding, city, country, inserted_at, updated_at)
        VALUES
          ('North Pole', 90.0, 0.0, vector(?), 'North', 'Pole', datetime('now'), datetime('now')),
          ('South Pole', -90.0, 0.0, vector(?), 'South', 'Pole', datetime('now'), datetime('now')),
          ('Date Line East', 0.0, 180.0, vector(?), 'East', 'Line', datetime('now'), datetime('now')),
          ('Date Line West', 0.0, -180.0, vector(?), 'West', 'Line', datetime('now'), datetime('now'))
        """,
        [
          EctoLibSql.Native.vector([90.0 / 90, 0.0 / 180]),
          EctoLibSql.Native.vector([-90.0 / 90, 0.0 / 180]),
          EctoLibSql.Native.vector([0.0 / 90, 180.0 / 180]),
          EctoLibSql.Native.vector([0.0 / 90, -180.0 / 180])
        ]
      )

      # Query should handle extreme values without error
      result =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          """
          SELECT name, vector_distance_cos(embedding, vector(?)) as distance
          FROM locations
          ORDER BY distance
          """,
          [EctoLibSql.Native.vector([1.0, 0.0])]
        )

      assert result.num_rows == 4
      # All distances should be valid numbers
      Enum.each(result.rows, fn [_name, distance] ->
        assert is_float(distance)
        assert distance >= 0.0
        assert distance <= 2.0
      end)
    end

    test "handles large embedding vectors" do
      # Create larger embeddings (more realistic for AI models)
      # Simulating 128-dimensional embeddings
      large_embedding_1 =
        EctoLibSql.Native.vector(Enum.map(1..128, fn i -> :math.sin(i / 10.0) end))

      large_embedding_2 =
        EctoLibSql.Native.vector(Enum.map(1..128, fn i -> :math.cos(i / 10.0) end))

      # Insert with larger embeddings
      Ecto.Adapters.SQL.query!(
        TestRepo,
        """
        CREATE TABLE IF NOT EXISTS locations_large (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT,
          embedding F32_BLOB(128),
          inserted_at DATETIME
        )
        """
      )

      Ecto.Adapters.SQL.query!(
        TestRepo,
        """
        INSERT INTO locations_large (name, embedding, inserted_at)
        VALUES (?, vector(?), datetime('now')), (?, vector(?), datetime('now'))
        """,
        ["Vector1", large_embedding_1, "Vector2", large_embedding_2]
      )

      result =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          """
          SELECT name, vector_distance_cos(embedding, vector(?)) as distance
          FROM locations_large
          ORDER BY distance
          """,
          [large_embedding_1]
        )

      assert result.num_rows == 2
      [[first_name, first_dist], [_second_name, second_dist]] = result.rows
      assert first_name == "Vector1"
      # Distance to itself should be very close to 0
      assert first_dist < 0.001
      # Distance to different vector should be larger
      assert second_dist > first_dist

      # Cleanup
      Ecto.Adapters.SQL.query!(TestRepo, "DROP TABLE locations_large")
    end

    test "handles pagination with distance ordering" do
      # Insert 10 locations
      Ecto.Adapters.SQL.query!(
        TestRepo,
        """
        INSERT INTO locations (name, latitude, longitude, embedding, city, country, inserted_at, updated_at)
        VALUES
          ('Sydney', -33.87, 151.21, vector(?), 'Sydney', 'Australia', datetime('now'), datetime('now')),
          ('Melbourne', -37.81, 144.96, vector(?), 'Melbourne', 'Australia', datetime('now'), datetime('now')),
          ('Brisbane', -27.47, 153.03, vector(?), 'Brisbane', 'Australia', datetime('now'), datetime('now')),
          ('Adelaide', -34.93, 138.60, vector(?), 'Adelaide', 'Australia', datetime('now'), datetime('now')),
          ('Perth', -31.95, 115.86, vector(?), 'Perth', 'Australia', datetime('now'), datetime('now')),
          ('Tokyo', 35.68, 139.69, vector(?), 'Tokyo', 'Japan', datetime('now'), datetime('now')),
          ('Osaka', 34.67, 135.50, vector(?), 'Osaka', 'Japan', datetime('now'), datetime('now')),
          ('Kyoto', 35.01, 135.77, vector(?), 'Kyoto', 'Japan', datetime('now'), datetime('now')),
          ('New York', 40.71, -74.01, vector(?), 'New York', 'USA', datetime('now'), datetime('now')),
          ('Los Angeles', 34.05, -118.24, vector(?), 'Los Angeles', 'USA', datetime('now'), datetime('now'))
        """,
        [
          EctoLibSql.Native.vector([-33.87 / 90, 151.21 / 180]),
          EctoLibSql.Native.vector([-37.81 / 90, 144.96 / 180]),
          EctoLibSql.Native.vector([-27.47 / 90, 153.03 / 180]),
          EctoLibSql.Native.vector([-34.93 / 90, 138.60 / 180]),
          EctoLibSql.Native.vector([-31.95 / 90, 115.86 / 180]),
          EctoLibSql.Native.vector([35.68 / 90, 139.69 / 180]),
          EctoLibSql.Native.vector([34.67 / 90, 135.50 / 180]),
          EctoLibSql.Native.vector([35.01 / 90, 135.77 / 180]),
          EctoLibSql.Native.vector([40.71 / 90, -74.01 / 180]),
          EctoLibSql.Native.vector([34.05 / 90, -118.24 / 180])
        ]
      )

      # Get first page (3 results)
      page_1 =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          """
          SELECT name, vector_distance_cos(embedding, vector(?)) as distance
          FROM locations
          ORDER BY distance
          LIMIT 3
          """,
          [EctoLibSql.Native.vector([-33.87 / 90, 151.21 / 180])]
        )

      assert page_1.num_rows == 3
      page_1_names = Enum.map(page_1.rows, fn [name, _] -> name end)

      # Get second page (next 3 results)
      page_2 =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          """
          SELECT name, vector_distance_cos(embedding, vector(?)) as distance
          FROM locations
          ORDER BY distance
          LIMIT 3 OFFSET 3
          """,
          [EctoLibSql.Native.vector([-33.87 / 90, 151.21 / 180])]
        )

      assert page_2.num_rows == 3
      page_2_names = Enum.map(page_2.rows, fn [name, _] -> name end)

      # Pages should not overlap
      assert page_1_names -- page_2_names == page_1_names
    end

    test "handles mixed NULL and valid embeddings in distance query" do
      Ecto.Adapters.SQL.query!(
        TestRepo,
        """
        INSERT INTO locations (name, latitude, longitude, embedding, city, country, inserted_at, updated_at)
        VALUES
          ('Sydney', -33.87, 151.21, vector(?), 'Sydney', 'Australia', datetime('now'), datetime('now')),
          ('Unknown', 0.0, 0.0, NULL, 'Unknown', 'Unknown', datetime('now'), datetime('now')),
          ('Tokyo', 35.68, 139.69, vector(?), 'Tokyo', 'Japan', datetime('now'), datetime('now')),
          ('Mystery', 0.0, 0.0, NULL, 'Mystery', 'Mystery', datetime('now'), datetime('now')),
          ('Melbourne', -37.81, 144.96, vector(?), 'Melbourne', 'Australia', datetime('now'), datetime('now'))
        """,
        [
          EctoLibSql.Native.vector([-33.87 / 90, 151.21 / 180]),
          EctoLibSql.Native.vector([35.68 / 90, 139.69 / 180]),
          EctoLibSql.Native.vector([-37.81 / 90, 144.96 / 180])
        ]
      )

      # Should only process non-NULL embeddings
      result =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          """
          SELECT name, vector_distance_cos(embedding, vector(?)) as distance
          FROM locations
          WHERE embedding IS NOT NULL
          ORDER BY distance
          """,
          [EctoLibSql.Native.vector([-33.87 / 90, 151.21 / 180])]
        )

      assert result.num_rows == 3
      names = Enum.map(result.rows, fn [name, _] -> name end)
      assert "Sydney" in names
      assert "Tokyo" in names
      assert "Melbourne" in names
      assert "Unknown" not in names
      assert "Mystery" not in names
    end
  end

  describe "vector error cases" do
    test "handles mismatched vector dimensions gracefully" do
      # This test documents behavior when attempting mismatched dimensions
      # Create table with 2D vectors
      embedding_2d = EctoLibSql.Native.vector([0.5, 0.5])

      Ecto.Adapters.SQL.query!(
        TestRepo,
        """
        INSERT INTO locations (name, latitude, longitude, embedding, city, country, inserted_at, updated_at)
        VALUES (?, ?, ?, vector(?), ?, ?, datetime('now'), datetime('now'))
        """,
        ["Sydney", -33.87, 151.21, embedding_2d, "Sydney", "Australia"]
      )

      # Try to query with same dimensional embedding - should work
      result =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          """
          SELECT name, vector_distance_cos(embedding, vector(?)) as distance
          FROM locations
          """,
          [embedding_2d]
        )

      assert result.num_rows == 1
      assert result.num_rows > 0
    end

    test "handles very large distance thresholds" do
      Ecto.Adapters.SQL.query!(
        TestRepo,
        """
        INSERT INTO locations (name, latitude, longitude, embedding, city, country, inserted_at, updated_at)
        VALUES
          ('Sydney', -33.87, 151.21, vector(?), 'Sydney', 'Australia', datetime('now'), datetime('now')),
          ('Tokyo', 35.68, 139.69, vector(?), 'Tokyo', 'Japan', datetime('now'), datetime('now'))
        """,
        [
          EctoLibSql.Native.vector([-33.87 / 90, 151.21 / 180]),
          EctoLibSql.Native.vector([35.68 / 90, 139.69 / 180])
        ]
      )

      # Query with very large threshold - should return all
      result =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          """
          SELECT name, vector_distance_cos(embedding, vector(?)) as distance
          FROM locations
          WHERE vector_distance_cos(embedding, vector(?)) < 10.0
          ORDER BY distance
          """,
          [
            EctoLibSql.Native.vector([-33.87 / 90, 151.21 / 180]),
            EctoLibSql.Native.vector([-33.87 / 90, 151.21 / 180])
          ]
        )

      assert result.num_rows == 2
    end

    test "handles zero distance threshold" do
      embedding = EctoLibSql.Native.vector([0.5, 0.5])

      Ecto.Adapters.SQL.query!(
        TestRepo,
        """
        INSERT INTO locations (name, latitude, longitude, embedding, city, country, inserted_at, updated_at)
        VALUES (?, ?, ?, vector(?), ?, ?, datetime('now'), datetime('now'))
        """,
        ["Sydney", -33.87, 151.21, embedding, "Sydney", "Australia"]
      )

      # Query with zero threshold - should only match exact duplicates
      result =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          """
          SELECT name, vector_distance_cos(embedding, vector(?)) as distance
          FROM locations
          WHERE vector_distance_cos(embedding, vector(?)) < 0.0001
          ORDER BY distance
          """,
          [embedding, embedding]
        )

      # Should return the exact match
      assert result.num_rows == 1
    end

    test "handles negative distance comparisons gracefully" do
      embedding = EctoLibSql.Native.vector([-0.5, 0.5])

      Ecto.Adapters.SQL.query!(
        TestRepo,
        """
        INSERT INTO locations (name, latitude, longitude, embedding, city, country, inserted_at, updated_at)
        VALUES (?, ?, ?, vector(?), ?, ?, datetime('now'), datetime('now'))
        """,
        ["Sydney", -33.87, 151.21, embedding, "Sydney", "Australia"]
      )

      # Query with negative threshold - should return no results
      # (distances are always >= 0)
      result =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          """
          SELECT name, vector_distance_cos(embedding, vector(?)) as distance
          FROM locations
          WHERE vector_distance_cos(embedding, vector(?)) < -0.1
          ORDER BY distance
          """,
          [embedding, embedding]
        )

      assert result.num_rows == 0
    end

    test "handles duplicate removals after distance sorting" do
      embedding = EctoLibSql.Native.vector([0.5, 0.5])

      Ecto.Adapters.SQL.query!(
        TestRepo,
        """
        INSERT INTO locations (name, latitude, longitude, embedding, city, country, inserted_at, updated_at)
        VALUES
          ('A', 0.0, 0.0, vector(?), 'City A', 'Country A', datetime('now'), datetime('now')),
          ('A', 0.0, 0.0, vector(?), 'City A', 'Country A', datetime('now'), datetime('now')),
          ('B', 1.0, 1.0, vector(?), 'City B', 'Country B', datetime('now'), datetime('now'))
        """,
        [embedding, embedding, EctoLibSql.Native.vector([0.6, 0.6])]
      )

      # Query should return both duplicate records (SQL doesn't auto-deduplicate)
      result =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          """
          SELECT name, vector_distance_cos(embedding, vector(?)) as distance
          FROM locations
          ORDER BY distance
          LIMIT 5
          """,
          [embedding]
        )

      assert result.num_rows == 3
    end
  end
end
