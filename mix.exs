defmodule LibSqlEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :libsqlex,
      version: "0.2.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "LibSqlEx",
      source_url: "https://github.com/danawanb/libsqlex",
      package: package(),
      description: description(),
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/danawanb/libsqlex"}
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp description() do
    "Unofficial Elixir database driver connection to libSQL/Turso."
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:rustler, "~> 0.36"},
      {:db_connection, "~> 2.1"},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end

  defp package() do
    [
      # These are the default files included in the package
      files: ~w(lib priv .formatter.exs mix.exs README* native ),
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/danawanb/libsqlex"}
    ]
  end
end
