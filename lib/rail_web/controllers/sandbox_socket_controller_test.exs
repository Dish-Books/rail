defmodule RailWeb.SandboxSocketControllerTest do
  use RailWeb.ConnCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Repo
  alias Rail.Tools.Schemas.Sandbox
  alias Rail.Users

  setup %{conn: conn, project: project} do
    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Issue", description: "Socket"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    token = "token-#{System.unique_integer([:positive])}"

    Repo.insert!(%Sandbox{
      task_id: task.id,
      engine: :docker,
      image: "rail-sandbox:latest",
      volume: "rail-socket",
      status: :starting,
      container_id: "c1",
      token_hash: :crypto.hash(:sha256, token)
    })

    # Plug keeps the host out of its headers, and the upgrade looks for it there, as a server would have it.
    conn =
      %{conn | req_headers: [{"host", "localhost"} | conn.req_headers]}
      |> put_req_header("connection", "upgrade")
      |> put_req_header("upgrade", "websocket")
      |> put_req_header("sec-websocket-version", "13")
      |> put_req_header("sec-websocket-key", Base.encode64(:crypto.strong_rand_bytes(16)))
      |> put_req_header("x-rail-sandbox-token", token)

    %{conn: conn}
  end

  test "a runner on Rail's own host is let in on its sandbox's token alone", %{conn: conn} do
    reject(Users, :verify_sandbox_access, 1)
    assert %Plug.Conn{state: :upgraded} = get(conn, ~p"/sandbox/socket")
  end

  test "a runner reaching Rail's port directly from elsewhere is refused, whatever its token", %{conn: conn} do
    reject(Users, :verify_sandbox_access, 1)

    for address <- [{10, 0, 0, 7}, {0, 0, 0, 0, 0, 0, 0, 2}, {0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 7}] do
      direct = Plug.Test.put_peer_data(conn, %{address: address, port: 50_000, ssl_cert: nil})
      assert direct |> get(~p"/sandbox/socket") |> response(403)
    end

    for address <- [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}, {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}] do
      local = Plug.Test.put_peer_data(conn, %{address: address, port: 50_000, ssl_cert: nil})
      assert %Plug.Conn{state: :upgraded} = get(local, ~p"/sandbox/socket")
    end
  end

  test "a token no live sandbox was started with is refused", %{conn: conn} do
    assert conn |> put_req_header("x-rail-sandbox-token", "nope") |> get(~p"/sandbox/socket") |> response(403)
  end

  test "a runner that came through Cloudflare needs the sandbox socket app's token as well", %{conn: conn} do
    stub(Users, :verify_sandbox_access, fn
      "good" -> :ok
      _other -> {:error, :invalid_assertion}
    end)

    through = put_req_header(conn, "cf-ray", "8f00-ORD")

    assert %Plug.Conn{state: :upgraded} =
             through |> put_req_header("cf-access-jwt-assertion", "good") |> get(~p"/sandbox/socket")

    assert through |> put_req_header("cf-access-jwt-assertion", "bad") |> get(~p"/sandbox/socket") |> response(403)
    assert through |> get(~p"/sandbox/socket") |> response(403)
  end
end
