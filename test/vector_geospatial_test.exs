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
        Ecto.Adapters.SQL.query!(TestRepo, """
        SELECT name, city, country, vector_distance_cos(embedding, vector(?)) as distance
        FROM locations
        ORDER BY distance
        LIMIT 3
        """, [sydney_embedding])

      # Should return Sydney first (distance 0 to itself), followed by other cities
      assert result.num_rows == 3
      [[sydney_name, _, _, sydney_dist], [second_name, _, _, second_dist], [third_name, _, _, third_dist]] =
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
      Ecto.Adapters.SQL.query!(TestRepo, """
      INSERT INTO locations (name, latitude, longitude, embedding, city, country, inserted_at, updated_at)
      VALUES
        ('Sydney', -33.87, 151.21, vector(?), 'Sydney', 'Australia', datetime('now'), datetime('now')),
        ('Melbourne', -37.81, 144.96, vector(?), 'Melbourne', 'Australia', datetime('now'), datetime('now')),
        ('Tokyo', 35.68, 139.69, vector(?), 'Tokyo', 'Japan', datetime('now'), datetime('now')),
        ('Osaka', 34.67, 135.50, vector(?), 'Osaka', 'Japan', datetime('now'), datetime('now')),
        ('New York', 40.71, -74.01, vector(?), 'New York', 'USA', datetime('now'), datetime('now'))
      """, [
        EctoLibSql.Native.vector([-33.87 / 90, 151.21 / 180]),
        EctoLibSql.Native.vector([-37.81 / 90, 144.96 / 180]),
        EctoLibSql.Native.vector([35.68 / 90, 139.69 / 180]),
        EctoLibSql.Native.vector([34.67 / 90, 135.50 / 180]),
        EctoLibSql.Native.vector([40.71 / 90, -74.01 / 180])
      ])

      # Find nearest location to Tokyo, but only in Asia
      tokyo_embedding = EctoLibSql.Native.vector([35.68 / 90, 139.69 / 180])

      result =
        Ecto.Adapters.SQL.query!(TestRepo, """
        SELECT name, city, country, vector_distance_cos(embedding, vector(?)) as distance
        FROM locations
        WHERE country IN ('Japan', 'Australia')
        ORDER BY distance
        LIMIT 2
        """, [tokyo_embedding])

      assert result.num_rows == 2
      [[first_name, _, first_country, first_dist], [second_name, _, _second_country, _second_dist]] =
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
      Ecto.Adapters.SQL.query!(TestRepo, """
      INSERT INTO locations (name, latitude, longitude, embedding, city, country, inserted_at, updated_at)
      VALUES
        ('Sydney', -33.87, 151.21, vector(?), 'Sydney', 'Australia', datetime('now'), datetime('now')),
        ('Melbourne', -37.81, 144.96, vector(?), 'Melbourne', 'Australia', datetime('now'), datetime('now')),
        ('Brisbane', -27.47, 153.03, vector(?), 'Brisbane', 'Australia', datetime('now'), datetime('now')),
        ('Tokyo', 35.68, 139.69, vector(?), 'Tokyo', 'Japan', datetime('now'), datetime('now')),
        ('New York', 40.71, -74.01, vector(?), 'New York', 'USA', datetime('now'), datetime('now'))
      """, [
        EctoLibSql.Native.vector([-33.87 / 90, 151.21 / 180]),
        EctoLibSql.Native.vector([-37.81 / 90, 144.96 / 180]),
        EctoLibSql.Native.vector([-27.47 / 90, 153.03 / 180]),
        EctoLibSql.Native.vector([35.68 / 90, 139.69 / 180]),
        EctoLibSql.Native.vector([40.71 / 90, -74.01 / 180])
      ])

      # Search for locations within a certain distance of Sydney
      # Using a threshold of 0.15 (roughly 15% of max distance in normalized space)
      sydney_embedding = EctoLibSql.Native.vector([-33.87 / 90, 151.21 / 180])

      result =
        Ecto.Adapters.SQL.query!(TestRepo, """
        SELECT name, country, vector_distance_cos(embedding, vector(?)) as distance
        FROM locations
        WHERE vector_distance_cos(embedding, vector(?)) < 0.15
        ORDER BY distance
        """, [sydney_embedding, sydney_embedding])

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
      Ecto.Adapters.SQL.query!(TestRepo, """
      INSERT INTO locations (name, latitude, longitude, embedding, city, country, inserted_at, updated_at)
      VALUES
        ('Sydney', -33.87, 151.21, vector(?), 'Sydney', 'Australia', datetime('now'), datetime('now')),
        ('Melbourne', -37.81, 144.96, vector(?), 'Melbourne', 'Australia', datetime('now'), datetime('now')),
        ('Brisbane', -27.47, 153.03, vector(?), 'Brisbane', 'Australia', datetime('now'), datetime('now')),
        ('Tokyo', 35.68, 139.69, vector(?), 'Tokyo', 'Japan', datetime('now'), datetime('now')),
        ('Osaka', 34.67, 135.50, vector(?), 'Osaka', 'Japan', datetime('now'), datetime('now')),
        ('New York', 40.71, -74.01, vector(?), 'New York', 'USA', datetime('now'), datetime('now')),
        ('Los Angeles', 34.05, -118.24, vector(?), 'Los Angeles', 'USA', datetime('now'), datetime('now'))
      """, [
        EctoLibSql.Native.vector([-33.87 / 90, 151.21 / 180]),
        EctoLibSql.Native.vector([-37.81 / 90, 144.96 / 180]),
        EctoLibSql.Native.vector([-27.47 / 90, 153.03 / 180]),
        EctoLibSql.Native.vector([35.68 / 90, 139.69 / 180]),
        EctoLibSql.Native.vector([34.67 / 90, 135.50 / 180]),
        EctoLibSql.Native.vector([40.71 / 90, -74.01 / 180]),
        EctoLibSql.Native.vector([34.05 / 90, -118.24 / 180])
      ])

      # Find the closest location to Sydney in each country
      sydney_embedding = EctoLibSql.Native.vector([-33.87 / 90, 151.21 / 180])

      result =
        Ecto.Adapters.SQL.query!(TestRepo, """
        SELECT
          country,
          name,
          vector_distance_cos(embedding, vector(?)) as distance
        FROM locations
        WHERE country != 'Australia'
        ORDER BY country, distance
        """, [sydney_embedding])

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
      Ecto.Adapters.SQL.query!(TestRepo, """
      INSERT INTO locations (name, latitude, longitude, embedding, city, country, inserted_at, updated_at)
      VALUES
        ('Sydney', -33.87, 151.21, vector(?), 'Sydney', 'Australia', datetime('now'), datetime('now')),
        ('Melbourne', -37.81, 144.96, vector(?), 'Melbourne', 'Australia', datetime('now'), datetime('now')),
        ('Tokyo', 35.68, 139.69, vector(?), 'Tokyo', 'Japan', datetime('now'), datetime('now')),
        ('Bangkok', 13.73, 100.50, vector(?), 'Bangkok', 'Thailand', datetime('now'), datetime('now')),
        ('Singapore', 1.35, 103.82, vector(?), 'Singapore', 'Singapore', datetime('now'), datetime('now')),
        ('New York', 40.71, -74.01, vector(?), 'New York', 'USA', datetime('now'), datetime('now'))
      """, [
        EctoLibSql.Native.vector([-33.87 / 90, 151.21 / 180]),
        EctoLibSql.Native.vector([-37.81 / 90, 144.96 / 180]),
        EctoLibSql.Native.vector([35.68 / 90, 139.69 / 180]),
        EctoLibSql.Native.vector([13.73 / 90, 100.50 / 180]),
        EctoLibSql.Native.vector([1.35 / 90, 103.82 / 180]),
        EctoLibSql.Native.vector([40.71 / 90, -74.01 / 180])
      ])

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
end
