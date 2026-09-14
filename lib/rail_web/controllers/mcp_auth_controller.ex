defmodule RailWeb.McpAuthController do
  use RailWeb, :controller

  alias Rail.Mcp

  def request(conn, %{"server_id" => server_id}) do
    state = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    with {:ok, server} <- Mcp.get_server(id: server_id),
         {:ok, url, verifier} <- Mcp.authorize_url(server, state) do
      conn
      |> put_session(:mcp_oauth, %{"state" => state, "verifier" => verifier, "server_id" => server.id})
      |> redirect(external: url)
    else
      _not_ready -> redirect_with(conn, :error, "That MCP server is not ready to connect.")
    end
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    pending = get_session(conn, :mcp_oauth)
    conn = delete_session(conn, :mcp_oauth)

    with %{"state" => expected, "verifier" => verifier, "server_id" => server_id} <- pending,
         true <- is_binary(state) and Plug.Crypto.secure_compare(expected, state),
         {:ok, server} <- Mcp.get_server(id: server_id),
         {:ok, _connection} <- Mcp.connect_server(conn.assigns.current_scope, server, code, verifier) do
      redirect_with(conn, :info, "Connected #{server.name}.")
    else
      _failed -> redirect_with(conn, :error, "MCP server authentication failed.")
    end
  end

  def callback(conn, %{"error" => _error}) do
    conn
    |> delete_session(:mcp_oauth)
    |> redirect_with(:error, "MCP server authentication was denied or cancelled.")
  end

  def callback(conn, _params) do
    redirect_with(conn, :error, "MCP server authentication failed.")
  end

  defp redirect_with(conn, kind, message) do
    conn
    |> put_flash(kind, message)
    |> redirect(to: ~p"/settings/connected-accounts")
  end
end
