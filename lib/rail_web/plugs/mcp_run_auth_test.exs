defmodule RailWeb.Plugs.McpRunAuthTest do
  use RailWeb.ConnCase, async: true

  alias Rail.Mcp
  alias Rail.Mcp.RunContext
  alias RailWeb.Plugs.McpRunAuth

  test "assigns the run context for a valid bearer token", %{conn: conn} do
    context = %RunContext{}
    expect(Mcp, :authenticate_run_token, fn "run_token" -> {:ok, context} end)

    conn = conn |> put_req_header("authorization", "Bearer run_token") |> McpRunAuth.call(McpRunAuth.init([]))

    assert %Plug.Conn{halted: false, assigns: %{mcp_context: ^context}} = conn
  end

  test "rejects a missing or unknown token with 401", %{conn: conn} do
    expect(Mcp, :authenticate_run_token, fn "stale" -> {:error, :invalid_token} end)

    stale = conn |> put_req_header("authorization", "Bearer stale") |> McpRunAuth.call([])
    missing = McpRunAuth.call(conn, [])

    for conn <- [stale, missing] do
      assert %Plug.Conn{halted: true, status: 401} = conn
      assert [~s(Bearer error="invalid_token")] = get_resp_header(conn, "www-authenticate")
    end
  end
end
