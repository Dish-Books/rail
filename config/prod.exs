import Config

config :logger, level: :info

config :rail, RailWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"
