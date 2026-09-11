import Config

config :logger, level: :warning, truncate: :infinity

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  enable_expensive_runtime_checks: true

config :rail, Rail.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 5432,
  database: "rail_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :rail, RailWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "rails_test_secret_key_base_at_least_64_bytes_long_for_security_123456789012",
  server: false

config :rail, :adopt_on_boot, false
config :rail, :enable_livesync, false

config :rail, :github,
  app_id: "test_github_app_id",
  private_key: File.read!("test/support/fixtures/github_app.pem"),
  req_options: [plug: {Req.Test, Rail.GitHub}]

config :rail, :linear,
  graphql_url: "https://api.linear.app/graphql",
  req_options: [plug: {Req.Test, Rail.Linear}]

config :rail, :linear_oauth,
  client_id: "test_linear_client_id",
  client_secret: "test_linear_client_secret",
  redirect_uri: "http://localhost:4002/auth/linear/callback",
  req_options: [plug: {Req.Test, Rail.Linear}]

config :rail, :no_dispatch, true
config :rail, :periodic, auto_start: false
config :rail, dev_routes: true
