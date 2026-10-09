import Config

config :logger, level: :warning, truncate: :infinity

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  enable_expensive_runtime_checks: true

config :rail, Oban, testing: :manual

config :rail, Rail.Repo,
  username: "postgres",
  password: "postgres",
  hostname: System.get_env("DB_HOST", "localhost"),
  port: String.to_integer(System.get_env("DB_PORT", "5432")),
  database: "rail_test#{System.get_env("DB_SUFFIX")}#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  # A test shares its one connection with its LiveViews, which reload on broadcasts from every other
  # test; under load the default target dropped a reload that was only waiting its turn.
  queue_target: 5_000,
  queue_interval: 10_000

config :rail, RailWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("TEST_PORT", "4002"))],
  secret_key_base: "rails_test_secret_key_base_at_least_64_bytes_long_for_security_123456789012",
  server: false

config :rail, :adopt_on_boot, false
config :rail, :backends_root, Path.join(System.tmp_dir!(), "rail_test_backends")
config :rail, :docker, req_options: [plug: {Req.Test, Rail.Tools.Clients.Docker}, retry: false]
config :rail, :fetch_parsers, false
config :rail, :github, req_options: [plug: {Req.Test, Rail.GitHub.Client}]
config :rail, :linear, req_options: [plug: {Req.Test, Rail.Linear}]
config :rail, :linear_oauth, req_options: [plug: {Req.Test, Rail.Linear}]
config :rail, :mcp, req_options: [plug: {Req.Test, Rail.Mcp}, retry: false]

# A fixed machine, so what fits and what waits does not depend on where the suite runs.
config :rail, :sandbox, runtime: :local, local_cpus: 4, local_memory_gb: 8, headroom_cpus: 0, headroom_memory_gb: 0
config :rail, :slack, req_options: [plug: {Req.Test, Rail.Slack}, retry: false]
config :rail, :slack_oauth, req_options: [plug: {Req.Test, Rail.Slack}, retry: false]
config :rail, :slack_socket, false
config :rail, :triage_runner, false
config :rail, :vertex, req_options: [plug: {Req.Test, Rail.Learnings.Clients.Vertex}, retry: false]
config :rail, dev_routes: true
config :rail, scratch_root: Path.join(System.tmp_dir!(), "rail")
