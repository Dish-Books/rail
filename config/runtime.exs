import Config

alias Ueberauth.Strategy.Github.OAuth

if config_env() == :dev and File.exists?(".env") do
  Dotenv.load!()
end

if System.get_env("PHX_SERVER") do
  config :rail, RailWeb.Endpoint, server: true
end

# GitHub App
if app_id = System.get_env("GITHUB_APP_ID") do
  config :rail, :github, app_id: app_id
end

if private_key = System.get_env("GITHUB_APP_PRIVATE_KEY") do
  config :rail, :github, private_key: private_key
end

# GitHub OAuth
if client_id = System.get_env("GITHUB_CLIENT_ID") do
  config :ueberauth, OAuth, client_id: client_id
end

if client_secret = System.get_env("GITHUB_CLIENT_SECRET") do
  config :ueberauth, OAuth, client_secret: client_secret
end

# Linear
if graphql_url = System.get_env("LINEAR_GRAPHQL_URL") do
  config :rail, :linear, graphql_url: graphql_url
end

if client_id = System.get_env("LINEAR_CLIENT_ID") do
  config :rail, :linear_oauth, client_id: client_id
end

if client_secret = System.get_env("LINEAR_CLIENT_SECRET") do
  config :rail, :linear_oauth, client_secret: client_secret
end

if redirect_uri = System.get_env("LINEAR_REDIRECT_URI") do
  config :rail, :linear_oauth, redirect_uri: redirect_uri
end

# Dev overrides
if config_env() == :dev do
  if port = System.get_env("PORT") do
    config :rail, RailWeb.Endpoint, http: [ip: {127, 0, 0, 1}, port: String.to_integer(port)]
  end

  if db_port = System.get_env("DB_PORT") do
    config :rail, Rail.Repo, port: String.to_integer(db_port)
  end

  if db_suffix = System.get_env("DB_SUFFIX") do
    config :rail, Rail.Repo, database: "rail_dev#{db_suffix}"
  end
end

# Test overrides
if config_env() == :test do
  if test_port = System.get_env("TEST_PORT") do
    config :rail, RailWeb.Endpoint, http: [ip: {127, 0, 0, 1}, port: String.to_integer(test_port)]
  end

  if db_host = System.get_env("DB_HOST") do
    config :rail, Rail.Repo, hostname: db_host
  end

  if db_port = System.get_env("DB_PORT") do
    config :rail, Rail.Repo, port: String.to_integer(db_port)
  end

  if System.get_env("DB_SUFFIX") || System.get_env("MIX_TEST_PARTITION") do
    db_suffix = System.get_env("DB_SUFFIX", "")
    partition = System.get_env("MIX_TEST_PARTITION", "")
    config :rail, Rail.Repo, database: "rail_test#{db_suffix}#{partition}"
  end
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  cloak_key =
    System.get_env("CLOAK_KEY_V1") ||
      raise """
      environment variable CLOAK_KEY_V1 is missing.
      """

  config :rail, Rail.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  config :rail, Rail.Vault,
    ciphers: [
      aes_gcm: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: Base.decode64!(cloak_key), iv_length: 12}
    ]

  config :rail, RailWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base
end

# The one gate on invoking an agent CLI. Read here so app code never touches the
# environment directly.
config :rail, :no_dispatch, System.get_env("RAIL_NO_DISPATCH") == "1"
