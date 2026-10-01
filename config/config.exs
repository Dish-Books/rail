import Config

config :elixir, :time_zone_database, Tz.TimeZoneDatabase

config :esbuild,
  version: "0.25.0",
  rail: [
    args: ~w(js/app.js --bundle --target=es2020 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

# Off until runtime.exs supplies the key in prod.
config :posthog,
  enable: false,
  in_app_otp_apps: [:rail],
  metadata: [:request_id]

config :rail, Oban,
  repo: Rail.Repo,
  queues: [issues: 5, tools: 1, git: 1],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"* * * * *", Rail.Tools.Workers.ReconcileOsProcesses},
       {"*/5 * * * *", Rail.Tools.Workers.RefreshUsage},
       {"*/15 * * * *", Rail.Git.Workers.FetchDefaultBranches}
     ]}
  ]

config :rail, Rail.Cache,
  gc_interval: to_timeout(hour: 12),
  max_size: 100_000,
  allocated_memory: 100_000_000,
  gc_memory_check_interval: to_timeout(second: 30)

config :rail, Rail.Repo,
  migration_primary_key: [type: :text],
  migration_timestamps: [type: :utc_datetime_usec]

config :rail, RailWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: RailWeb.ErrorHTML, json: RailWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Rail.PubSub,
  live_view: [signing_salt: "rail_lv_salt_1234"]

config :rail, :fetch_parsers, true

# Where agents, setup and CI run, and what is kept back for Rail, Postgres and project services.
# The machine's CPUs and memory are read at runtime; only `:docker` (prod) enforces a reservation.
config :rail, :sandbox,
  runtime: :local,
  image: "rail-sandbox:latest",
  binds: ["/srv/rail:/srv/rail"],
  headroom_cpus: 2,
  headroom_memory_gb: 8,
  shm_size_gb: 1

config :rail,
  config_env: config_env(),
  dev_routes: false,
  scratch_root: Path.expand("../output", __DIR__),
  ecto_repos: [Rail.Repo],
  generators: [timestamp_type: :utc_datetime_usec]

config :tailwind,
  version: "4.3.0",
  rail: [
    args: ~w(
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

config :ueberauth, Ueberauth,
  providers: [
    github: {Ueberauth.Strategy.Github, [default_scope: "read:user,user:email,repo"]}
  ]

import_config "#{config_env()}.exs"
