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

config :rail, Rail.Repo,
  migration_primary_key: [type: :text],
  migration_timestamps: [type: :utc_datetime_usec]

config :rail, Rail.Vault,
  ciphers: [
    aes_gcm:
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1", key: Base.decode64!("L2zKQh+tDxkUH94a2O+oa8Mae3mryHitrR/LrYABeNA="), iv_length: 12}
  ]

config :rail, RailWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: RailWeb.ErrorHTML, json: RailWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Rail.PubSub,
  live_view: [signing_salt: "rail_lv_salt_1234"]

config :rail, :github,
  app_id: System.get_env("GITHUB_APP_ID", "test_app_id"),
  private_key: System.get_env("GITHUB_APP_PRIVATE_KEY")

config :rail, :linear, graphql_url: System.get_env("LINEAR_GRAPHQL_URL", "https://api.linear.app/graphql")

config :rail, :linear_oauth,
  client_id: System.get_env("LINEAR_CLIENT_ID", "linear_client_id"),
  client_secret: System.get_env("LINEAR_CLIENT_SECRET", "linear_client_secret"),
  redirect_uri: System.get_env("LINEAR_REDIRECT_URI", "http://localhost:4000/auth/linear/callback")

config :rail,
  config_env: config_env(),
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

config :ueberauth, Ueberauth.Strategy.Github.OAuth,
  client_id: System.get_env("GITHUB_CLIENT_ID", "github_client_id"),
  client_secret: System.get_env("GITHUB_CLIENT_SECRET", "github_client_secret")

import_config "#{config_env()}.exs"
