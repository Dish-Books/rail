import Config

if config_env() == :dev and File.exists?(".env"), do: Dotenv.load!()

cloak_key =
  if config_env() == :prod do
    System.fetch_env!("CLOAK_KEY_V1")
  else
    System.get_env("CLOAK_KEY_V1", "L2zKQh+tDxkUH94a2O+oa8Mae3mryHitrR/LrYABeNA=")
  end

config :rail, Rail.Vault,
  ciphers: [
    aes_gcm: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: Base.decode64!(cloak_key), iv_length: 12}
  ]

config :rail, :git,
  bot_name: "Rail",
  bot_email: "rail[bot]@railai.dev"

config :rail, :github,
  app_id: System.get_env("GITHUB_APP_ID", "test_app_id"),
  private_key: System.get_env("GITHUB_APP_PRIVATE_KEY", "test/support/fixtures/github_app.pem")

config :rail, :linear_oauth,
  client_id: System.get_env("LINEAR_CLIENT_ID", "linear_client_id"),
  client_secret: System.get_env("LINEAR_CLIENT_SECRET", "linear_client_secret")

# The one gate on invoking an agent CLI. Read here so app code never touches the
# environment directly.
config :rail, :no_dispatch, System.get_env("RAIL_NO_DISPATCH") == "1"

config :ueberauth, Ueberauth.Strategy.Github.OAuth,
  client_id: System.get_env("GITHUB_CLIENT_ID", "github_client_id"),
  client_secret: System.get_env("GITHUB_CLIENT_SECRET", "github_client_secret")

if config_env() == :prod do
  config :rail, Rail.Repo,
    url: System.fetch_env!("DATABASE_URL"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10")),
    socket_options: if(System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: [])

  config :rail, RailWeb.Endpoint,
    url: [host: System.fetch_env!("PHX_HOST"), port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4000"))],
    secret_key_base: System.fetch_env!("SECRET_KEY_BASE"),
    server: System.get_env("PHX_SERVER") != nil
end
