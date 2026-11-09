defmodule Rail.MixProject do
  use Mix.Project

  def project do
    [
      app: :rail,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      test_paths: ["lib"],
      test_coverage: [tool: ExCoveralls, export: "excoveralls"],
      releases: [
        rail: [
          include_executables_for: [:unix],
          applications: [runtime_tools: :permanent]
        ]
      ]
    ]
  end

  def application do
    [
      mod: {Rail.Application, []},
      extra_applications: [:logger, :runtime_tools, :ssh]
    ]
  end

  def cli do
    [
      preferred_envs: [
        precommit: :test,
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test,
        "coveralls.json": :test,
        "test.watch": :test
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:attrs, "~> 0.6"},
      {:bandit, "~> 1.14"},
      {:cloak_ecto, github: "michaelst/cloak_ecto", ref: "5a97ae633be28d5d98d010450a396e11c65d5cc8"},
      {:credo, "~> 1.7", only: :dev, runtime: false},
      {:rail_credo, path: "credo", only: :dev},
      {:decimal, "~> 3.2"},
      {:decorator, "~> 1.4"},
      {:dotenv, "~> 3.1", only: [:dev, :test]},
      {:ecto_sql, "~> 3.14"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:excoveralls, "~> 0.18", only: :test},
      {:floki, "~> 0.38"},
      {:gettext, "~> 1.0"},
      {:goth, "~> 1.4"},
      {:jason, "~> 1.4"},
      {:jose, "~> 1.11"},
      {:mdex, "~> 0.14"},
      {:lazy_html, "~> 0.1", only: :test},
      {:logger_json, "~> 7.0"},
      {:lumis, "~> 0.10"},
      {:lumis_wasm_bundle_full, "~> 0.2"},
      {:mimic, "~> 2.5", only: :test},
      {:mint_web_socket, "~> 1.0"},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:mix_test_watch, "~> 1.4", only: [:dev, :test], runtime: false},
      {:oban, "~> 2.24"},
      {:oban_web, "~> 2.13"},
      {:phoenix_ecto, "~> 4.7"},
      {:phoenix_html, "~> 4.4"},
      {:phoenix_live_dashboard, "~> 0.9"},
      {:phoenix_live_reload, "~> 1.7", only: :dev},
      {:phoenix_live_view, "~> 1.2"},
      {:phoenix, "~> 1.8.16"},
      {:pgvector, "~> 0.4"},
      {:postgrex, "~> 0.22"},
      {:posthog, "~> 2.20"},
      {:req, "~> 0.7"},
      {:sobelow, "~> 0.18", only: [:dev, :test], runtime: false},
      {:styler, "~> 1.12", only: [:dev, :test], runtime: false},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:telemetry_metrics, "~> 1.2"},
      {:telemetry_poller, "~> 1.3"},
      {:tz, "~> 0.28"},
      {:ueberauth, "~> 0.11"},
      {:ueberauth_github, "~> 0.8"},
      {:uxid, "~> 2.10"},
      {:yaml_elixir, "~> 2.12"}
    ]
  end

  defp aliases do
    [
      credo: ["credo --config-file .credo.exs"],
      setup: ["deps.get", "ecto.setup", "assets.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test --warnings-as-errors"],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"],
      "assets.setup": [
        "tailwind.install --if-missing",
        "esbuild.install --if-missing",
        "cmd --cd assets pnpm install"
      ],
      "assets.deploy": [
        "cmd --cd assets pnpm install --frozen-lockfile",
        "tailwind rail --minify",
        "esbuild rail --minify",
        "esbuild design_overlay --minify",
        "esbuild design_kit --minify",
        "phx.digest"
      ]
    ]
  end
end
