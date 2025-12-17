defmodule EctoLibSql.MixProject do
  use Mix.Project

  @version "0.8.0"
  @source_url "https://github.com/ocean/ecto_libsql"

  def project do
    [
      app: :ecto_libsql,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "EctoLibSql",
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      description: description(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp description() do
    """
    Elixir Ecto adapter for LibSQL and Turso databases. Supports local SQLite files,
    remote Turso cloud databases, and embedded replicas with sync. Built with
    Rust NIFs for reliability and fault tolerance.

    See the Changelog for details!
    """
  end

  defp deps do
    [
      {:rustler, "~> 0.37.1"},
      {:db_connection, "~> 2.1"},
      {:ecto, "~> 3.11"},
      {:ecto_sql, "~> 3.11"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:jason, "~> 1.4"}
    ]
  end

  defp package() do
    [
      name: "ecto_libsql",
      files: ~w(lib priv .formatter.exs mix.exs README* LICENSE* CHANGELOG* AGENT* native),
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "https://hexdocs.pm/ecto_libsql/changelog.html"
      },
      maintainers: ["ocean"]
    ]
  end

  defp docs do
    [
      main: "EctoLibSql",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md", "AGENTS.md", "ECTO_MIGRATION_GUIDE.md"],
      groups_for_modules: [
        "Core Modules": [EctoLibSql, EctoLibSql.Native],
        "Support Modules": [
          EctoLibSql.Query,
          EctoLibSql.Result,
          EctoLibSql.State,
          EctoLibSql.Error
        ],
        "Ecto Integration": [
          Ecto.Adapters.LibSql,
          Ecto.Adapters.LibSql.Connection
        ]
      ]
    ]
  end
end
