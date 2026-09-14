defmodule RailWeb.Plugs.McpRunAuth do
  @moduledoc """
  Authenticates a request to the MCP proxy by the run token its agent CLI was
  spawned with, and assigns the resulting `%Rail.Mcp.RunContext{}` as
  `:mcp_context`.
  """

  import Plug.Conn

  alias Rail.Mcp

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, context} <- Mcp.authenticate_run_token(token) do
      assign(conn, :mcp_context, context)
    else
      _unauthenticated ->
        conn
        |> put_resp_header("www-authenticate", ~s(Bearer error="invalid_token"))
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{"error" => "invalid_token"}))
        |> halt()
    end
  end
end
