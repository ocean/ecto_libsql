defmodule EctoLibSql.EctoStreamCompatTest do
  @moduledoc """
  Tests ported from ecto_sql to verify streaming/cursor compatibility.
  Source: ecto_sql/integration_test/sql/stream.exs

  These tests verify that EctoLibSql correctly handles:
  - Streaming empty result sets
  - Streaming without schema (schemaless queries)
  - Streaming with associations
  - Cursor lifecycle and memory management
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  # Define test repo
  defmodule TestRepo do
    use Ecto.Repo,
      otp_app: :ecto_libsql,
      adapter: Ecto.Adapters.LibSql
  end

  defmodule Post do
    use Ecto.Schema

    schema "posts" do
      field(:title, :string)
      field(:body, :string)
      has_many(:comments, EctoLibSql.EctoStreamCompatTest.Comment)
      timestamps()
    end
  end

  defmodule Comment do
    use Ecto.Schema

    schema "comments" do
      field(:text, :string)
      belongs_to(:post, EctoLibSql.EctoStreamCompatTest.Post)
      timestamps()
    end
  end

  @test_db "z_ecto_libsql_test-stream_compat.db"

  setup_all do
    # Start the test repo
    {:ok, _} = TestRepo.start_link(database: @test_db)

    # Create posts table
    Ecto.Adapters.SQL.query!(TestRepo, """
    CREATE TABLE IF NOT EXISTS posts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT,
      body TEXT,
      inserted_at DATETIME,
      updated_at DATETIME
    )
    """)

    # Create comments table
    Ecto.Adapters.SQL.query!(TestRepo, """
    CREATE TABLE IF NOT EXISTS comments (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      text TEXT,
      post_id INTEGER,
      inserted_at DATETIME,
      updated_at DATETIME,
      FOREIGN KEY (post_id) REFERENCES posts(id)
    )
    """)

    on_exit(fn ->
      EctoLibSql.TestHelpers.cleanup_db_files(@test_db)
    end)

    :ok
  end

  setup do
    # Clean tables before each test
    Ecto.Adapters.SQL.query!(TestRepo, "DELETE FROM comments")
    Ecto.Adapters.SQL.query!(TestRepo, "DELETE FROM posts")
    :ok
  end

  describe "basic streaming" do
    test "stream empty result set" do
      assert {:ok, []} =
               TestRepo.transaction(fn ->
                 TestRepo.stream(Post)
                 |> Enum.to_list()
               end)

      assert {:ok, []} =
               TestRepo.transaction(fn ->
                 TestRepo.stream(from(p in Post))
                 |> Enum.to_list()
               end)
    end

    test "stream without schema (schemaless query)" do
      %Post{} = TestRepo.insert!(%Post{title: "title1"})
      %Post{} = TestRepo.insert!(%Post{title: "title2"})

      assert {:ok, ["title1", "title2"]} =
               TestRepo.transaction(fn ->
                 TestRepo.stream(from(p in "posts", order_by: p.title, select: p.title))
                 |> Enum.to_list()
               end)
    end

    test "stream with association" do
      p1 = TestRepo.insert!(%Post{title: "Post 1"})

      %Comment{id: cid1} = TestRepo.insert!(%Comment{text: "Comment 1", post_id: p1.id})
      %Comment{id: cid2} = TestRepo.insert!(%Comment{text: "Comment 2", post_id: p1.id})

      stream = TestRepo.stream(Ecto.assoc(p1, :comments))

      assert {:ok, [c1, c2]} =
               TestRepo.transaction(fn ->
                 Enum.to_list(stream)
               end)

      assert c1.id == cid1
      assert c2.id == cid2
    end
  end

  describe "streaming large datasets" do
    test "stream multiple records efficiently" do
      # Insert 100 posts
      posts =
        Enum.map(1..100, fn i ->
          %{title: "Post #{i}", body: "Body #{i}"}
        end)

      TestRepo.insert_all(Post, posts)

      # Stream and count them
      assert {:ok, count} =
               TestRepo.transaction(fn ->
                 TestRepo.stream(Post)
                 |> Enum.count()
               end)

      assert count == 100
    end

    test "stream with query and transformations" do
      # Insert posts
      posts = Enum.map(1..50, fn i -> %{title: "Post #{i}", body: nil} end)
      TestRepo.insert_all(Post, posts)

      # Stream, filter, and transform
      assert {:ok, titles} =
               TestRepo.transaction(fn ->
                 from(p in Post, order_by: p.id, limit: 10)
                 |> TestRepo.stream()
                 |> Stream.map(fn post -> post.title end)
                 |> Enum.to_list()
               end)

      assert length(titles) == 10
      assert Enum.at(titles, 0) == "Post 1"
    end
  end

  describe "cursor memory management" do
    test "cursor is properly cleaned up after streaming" do
      # Insert data
      Enum.each(1..10, fn i ->
        TestRepo.insert!(%Post{title: "Post #{i}"})
      end)

      # First stream
      {:ok, _} =
        TestRepo.transaction(fn ->
          TestRepo.stream(Post) |> Enum.to_list()
        end)

      # Second stream should work fine (cursor was cleaned up)
      {:ok, count} =
        TestRepo.transaction(fn ->
          TestRepo.stream(Post) |> Enum.count()
        end)

      assert count == 10
    end

    test "multiple sequential streams" do
      # Insert posts and comments
      p1 = TestRepo.insert!(%Post{title: "Post 1"})
      p2 = TestRepo.insert!(%Post{title: "Post 2"})

      TestRepo.insert!(%Comment{text: "C1", post_id: p1.id})
      TestRepo.insert!(%Comment{text: "C2", post_id: p2.id})

      # Stream both in same transaction
      {:ok, {posts, comments}} =
        TestRepo.transaction(fn ->
          post_stream = TestRepo.stream(Post) |> Enum.to_list()
          comment_stream = TestRepo.stream(Comment) |> Enum.to_list()
          {post_stream, comment_stream}
        end)

      assert length(posts) == 2
      assert length(comments) == 2
    end
  end

  describe "streaming with max_rows" do
    test "stream respects max_rows option" do
      # Insert 50 posts
      Enum.each(1..50, fn i ->
        TestRepo.insert!(%Post{title: "Post #{i}"})
      end)

      # Stream with max_rows of 10 - the stream returns individual items
      # not batches, but fetches them in chunks of max_rows from the database
      {:ok, posts} =
        TestRepo.transaction(fn ->
          TestRepo.stream(Post, max_rows: 10)
          |> Enum.take(25)
          |> Enum.to_list()
        end)

      # Should have fetched 25 posts
      assert length(posts) == 25
      # All should be Post structs
      assert Enum.all?(posts, fn p -> is_struct(p, Post) end)
    end
  end
end
