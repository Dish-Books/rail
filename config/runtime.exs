import Config

if System.get_env("PHX_SERVER") do
  config :rail, RailWeb.Endpoint, server: true
end

if client_id = System.get_env("LINEAR_CLIENT_ID") do
  config :rail, :linear_oauth,
    client_id: client_id,
    client_secret: System.get_env("LINEAR_CLIENT_SECRET"),
    redirect_uri: System.get_env("LINEAR_REDIRECT_URI", "http://localhost:4000/auth/linear/callback")
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
