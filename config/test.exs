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
  pool_size: System.schedulers_online() * 2

config :rail, RailWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("TEST_PORT", "4002"))],
  secret_key_base: "rails_test_secret_key_base_at_least_64_bytes_long_for_security_123456789012",
  server: false

config :rail, :adopt_on_boot, false
config :rail, :backends_root, Path.join(System.tmp_dir!(), "rail_test_backends")
config :rail, :github, req_options: [plug: {Req.Test, Rail.GitHub}]
config :rail, :linear, req_options: [plug: {Req.Test, Rail.Linear}]
config :rail, :linear_oauth, req_options: [plug: {Req.Test, Rail.Linear}]
config :rail, :mcp, req_options: [plug: {Req.Test, Rail.Mcp}, retry: false]
config :rail, dev_routes: true
