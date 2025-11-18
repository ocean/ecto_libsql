defmodule EctoLibSql.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/ocean/libsqlex"

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
    Ecto adapter for LibSQL and Turso databases. Supports local SQLite files,
    remote LibSQL/Turso connections, and embedded replicas with sync. Features
    include full transaction support, prepared statements, batch operations,
    vector similarity search, and cursor-based streaming for large result sets.

    Originally forked from https://github.com/danawanb/libsqlex
    """
  end

  defp deps do
    [
      {:rustler, "~> 0.36"},
      {:db_connection, "~> 2.1"},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp package() do
    [
      name: "ecto_libsql",
      files: ~w(
        lib
        priv
        native/ecto_libsql/src
        native/ecto_libsql/Cargo.*
        native/ecto_libsql/README.md
        .formatter.exs
        mix.exs
        README.md
        LICENSE
        CHANGELOG.md
      ),
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Original Project" => "https://github.com/danawanb/libsqlex",
        "Turso" => "https://turso.tech",
        "LibSQL" => "https://libsql.org"
      },
      maintainers: ["ocean"]
    ]
  end

  defp docs do
    [
      main: "EctoLibSql",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: [
        "README.md": [title: "Overview"],
        "CHANGELOG.md": [title: "Changelog"],
        "LICENSE": [title: "License"]
      ],
      groups_for_modules: [
        "Core Modules": [
          EctoLibSql,
          EctoLibSql.State,
          EctoLibSql.Query,
          EctoLibSql.Result
        ],
        "Native Interface": [
          EctoLibSql.Native
        ]
      ]
    ]
  end
end
