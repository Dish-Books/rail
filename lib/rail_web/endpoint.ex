defmodule RailWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :rail

  @cookie_secure Application.compile_env(:rail, :config_env) == :prod

  @session_options [
    store: :cookie,
    key: "_rail_key",
    signing_salt: "rail_session_salt_1234",
    same_site: "Lax",
    secure: @cookie_secure
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :rail,
    gzip: not code_reloading?,
    only: RailWeb.static_paths()

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    body_reader: {RailWeb.Plugs.CacheBodyReader, :read_body, []},
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug RailWeb.Router
end
