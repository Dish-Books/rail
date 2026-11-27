defmodule RailWeb.SandboxSocketController do
  use RailWeb, :controller

  alias Rail.Tools.RunnerSocket
  alias Rail.Users

  # Rail closes a socket it has heard nothing on for this long; the runner pings well inside it.
  @timeout_ms 60_000

  # A runner on Rail's own host dials it on loopback. Any other must come through Cloudflare and carry the sandbox
  # socket app's token: a direct connection could leave `Cf-Ray` off, so where it came from decides, not its headers.
  def connect(conn, _params) do
    with :ok <- through_access(conn),
         {:ok, state} <- RunnerSocket.connect(conn.req_headers) do
      conn
      |> WebSockAdapter.upgrade(RunnerSocket, state, timeout: @timeout_ms)
      |> halt()
    else
      _refused -> send_resp(conn, 403, "")
    end
  end

  # The socket's own peer, not anything a proxy header says.
  defp through_access(conn) do
    case {get_req_header(conn, "cf-ray"), get_req_header(conn, "cf-access-jwt-assertion")} do
      {[], _assertion} -> if loopback?(Plug.Conn.get_peer_data(conn).address), do: :ok, else: {:error, :not_local}
      {_cloudflare, [assertion | _rest]} -> Users.verify_sandbox_access(assertion)
      {_cloudflare, []} -> {:error, :no_assertion}
    end
  end

  defp loopback?({127, _b, _c, _d}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0xFFFF, a, _b}) when a in 0x7F00..0x7FFF, do: true
  defp loopback?(_address), do: false
end
