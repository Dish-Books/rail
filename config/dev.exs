import Config

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :plug_init_mode, :runtime
config :phoenix, :stacktrace_depth, 20

config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true,
  enable_expensive_runtime_checks: true

config :rail, Rail.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 5432,
  database: "rail_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :rail, RailWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "rails_development_secret_key_base_at_least_64_bytes_long_for_security_1234567890",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:rail, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:rail, ~w(--watch)]}
  ]

config :rail, dev_routes: true
