defmodule Rail.Tools.SandboxProxyTest do
  use Rail.DataCase, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Claude
  alias Rail.Tools.SandboxProxy
  alias Rail.Tools.Schemas.Backend
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Tools.Schemas.Sandbox

  setup do
    key = "SP#{System.unique_integer([:positive])}"

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Proxy",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}/clone"
      })

    issue =
      %Issue{}
      |> Issue.changeset(%{project_id: project.id, identifier: "#{key}-1", title: "Proxy", state: :todo})
      |> Repo.insert!()

    task =
      %Task{}
      |> Task.changeset(
        %{
          issue_id: issue.id,
          stage: :engineer,
          worktree_name: "p-1",
          worktree_path: "/w/#{key}",
          scratch_path: "/s/#{key}"
        },
        project.id
      )
      |> Repo.insert!()

    {:ok, role} =
      Roles.create_role(system_scope(), project, %{
        stage: :engineer,
        cli: :claude,
        name: "Engineer",
        model: "claude-proxy",
        system_prompt: "Build it."
      })

    {:ok, run} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :running, started_at: DateTime.utc_now()})

    {:ok, backend} = Tools.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true", label: key})

    sandbox =
      Repo.insert!(%Sandbox{task_id: task.id, engine: :docker, image: "i", volume: "v-#{key}", status: :running})

    token = "mcp-#{key}"

    turn =
      Repo.insert!(%OsProcess{
        run_id: run.id,
        task_id: task.id,
        sandbox_id: sandbox.id,
        backend_id: backend.id,
        kind: :agent,
        stream_path: "/dev/null",
        status: :running,
        started_at: DateTime.utc_now(),
        mcp_token_hash: :crypto.hash(:sha256, token)
      })

    stub(Claude, :access_token, fn %Backend{id: id} when id == backend.id -> {:ok, "account-token"} end)

    %{backend: backend, mcp_token: token, sandbox: sandbox, turn: turn}
  end

  test "a turn's message goes to Claude with its account's token, and the answer streams back", %{
    sandbox: sandbox,
    turn: turn
  } do
    Req.Test.stub(SandboxProxy, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/messages"
      assert conn.query_string == "beta=true"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer account-token"]
      assert Plug.Conn.get_req_header(conn, "x-api-key") == []
      assert Plug.Conn.get_req_header(conn, "cookie") == []
      assert Plug.Conn.get_req_header(conn, "anthropic-beta") == ["claude-code-20250219,oauth-2025-04-20"]
      assert {:ok, ~s({"stream":true}), conn} = Plug.Conn.read_body(conn)

      conn =
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.put_resp_header("request-id", "req_1")
        |> Plug.Conn.send_chunked(200)

      {:ok, conn} = Plug.Conn.chunk(conn, "event: message_start\n\n")
      {:ok, conn} = Plug.Conn.chunk(conn, "event: message_stop\n\n")
      conn
    end)

    open =
      claude_open(turn.id, "/v1/messages?beta=true", %{
        "authorization" => ["Bearer rail-sandbox-x"],
        "x-api-key" => ["nope"],
        "cookie" => ["a=b"],
        "anthropic-beta" => ["claude-code-20250219"]
      })

    SandboxProxy.claude(self(), 3, sandbox.id, open, ~s({"stream":true}))

    assert [{:http_head, 3, 200, headers} | rest] = proxy_answer(3)
    assert {:http_end, 3} = List.last(rest)

    assert Enum.map_join(rest, fn
             {:http_body, 3, bytes} -> bytes
             {:http_end, 3} -> ""
           end) ==
             "event: message_start\n\nevent: message_stop\n\n"

    assert {"request-id", ["req_1"]} in headers
    refute Enum.any?(headers, fn {name, _values} -> name == "content-length" end)
  end

  test "the oauth beta is kept once, and a body Claude answers without still gets its head", %{
    sandbox: sandbox,
    turn: turn
  } do
    Req.Test.stub(SandboxProxy, fn conn ->
      assert Plug.Conn.get_req_header(conn, "anthropic-beta") == ["oauth-2025-04-20,x"]
      Plug.Conn.send_resp(conn, 200, "")
    end)

    SandboxProxy.claude(
      self(),
      5,
      sandbox.id,
      claude_open(turn.id, "/v1/messages/count_tokens", %{"anthropic-beta" => ["oauth-2025-04-20, x"]}),
      "{}"
    )

    assert [{:http_head, 5, 200, _headers}, {:http_end, 5}] = proxy_answer(5)

    Req.Test.stub(SandboxProxy, fn conn ->
      assert Plug.Conn.get_req_header(conn, "anthropic-beta") == ["oauth-2025-04-20"]
      Plug.Conn.send_resp(conn, 200, "")
    end)

    SandboxProxy.claude(self(), 7, sandbox.id, Map.put(claude_open(turn.id, "/v1/messages", nil), "headers", nil), "{}")
    assert [{:http_head, 7, 200, _headers}, {:http_end, 7}] = proxy_answer(7)
  end

  test "a refused token is refreshed once and the message asked again", %{backend: backend, sandbox: sandbox, turn: turn} do
    expect(Claude, :refresh_access_token, fn %Backend{}, "account-token" -> {:ok, "renewed"} end)

    Req.Test.stub(SandboxProxy, fn conn ->
      case Plug.Conn.get_req_header(conn, "authorization") do
        ["Bearer account-token"] -> Plug.Conn.send_resp(conn, 401, ~s({"error":"expired"}))
        ["Bearer renewed"] -> Plug.Conn.send_resp(conn, 200, "ok")
      end
    end)

    SandboxProxy.claude(self(), 9, sandbox.id, claude_open(turn.id, "/v1/messages", %{}), "{}")
    assert [{:http_head, 9, 200, _headers}, {:http_body, 9, "ok"}, {:http_end, 9}] = proxy_answer(9)

    # Refused again, the second refusal is the CLI's to see.
    expect(Claude, :refresh_access_token, fn ^backend, "account-token" -> {:ok, "account-token"} end)
    Req.Test.stub(SandboxProxy, fn conn -> Plug.Conn.send_resp(conn, 401, "no") end)
    SandboxProxy.claude(self(), 11, sandbox.id, claude_open(turn.id, "/v1/messages", %{}), "{}")
    assert [{:http_head, 11, 401, _headers}, {:http_body, 11, "no"}, {:http_end, 11}] = proxy_answer(11)

    expect(Claude, :refresh_access_token, fn _backend, _stale -> {:error, :signed_out} end)
    SandboxProxy.claude(self(), 13, sandbox.id, claude_open(turn.id, "/v1/messages", %{}), "{}")
    assert [{:http_head, 13, 401, _headers}, {:http_body, 13, body}, {:http_end, 13}] = proxy_answer(13)
    assert body =~ "could not refresh"
  end

  test "Claude out of reach is a 502", %{sandbox: sandbox, turn: turn} do
    Req.Test.stub(SandboxProxy, &Req.Test.transport_error(&1, :econnrefused))
    SandboxProxy.claude(self(), 1, sandbox.id, claude_open(turn.id, "/v1/messages", %{}), "{}")
    assert [{:http_head, 1, 502, _headers}, {:http_body, 1, body}, {:http_end, 1}] = proxy_answer(1)
    assert body =~ "could not reach Claude"
  end

  test "nothing but messages, from a turn running in this sandbox on a usable login, reaches Claude", %{
    sandbox: sandbox,
    turn: turn
  } do
    other =
      Repo.insert!(%Sandbox{task_id: turn.task_id, engine: :docker, image: "i", volume: "other", status: :ended})

    for {open, status} <- [
          {claude_open(turn.id, "/v1/models", %{}), 403},
          {%{claude_open(turn.id, "/v1/messages", %{}) | "method" => "GET"}, 403},
          {claude_open(nil, "/v1/messages", %{}), 401}
        ] do
      SandboxProxy.claude(self(), 1, sandbox.id, open, "")
      assert [{:http_head, 1, ^status, _headers}, {:http_body, 1, _body}, {:http_end, 1}] = proxy_answer(1)
    end

    SandboxProxy.claude(self(), 1, other.id, claude_open(turn.id, "/v1/messages", %{}), "")
    assert [{:http_head, 1, 401, _headers}, _body, _end] = proxy_answer(1)

    stub(Claude, :access_token, fn _backend -> {:error, :signed_out} end)
    SandboxProxy.claude(self(), 1, sandbox.id, claude_open(turn.id, "/v1/messages", %{}), "")
    assert [{:http_head, 1, 401, _headers}, {:http_body, 1, body}, _end] = proxy_answer(1)
    assert body =~ "signed_out"
  end

  test "an agent's MCP call is answered by Rail's MCP server, as its own turn only", %{
    mcp_token: token,
    sandbox: sandbox
  } do
    auth = %{"authorization" => ["Bearer #{token}"]}
    ping = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

    SandboxProxy.mcp(self(), 2, sandbox.id, %{"method" => "POST", "headers" => auth}, ping)
    assert [{:http_head, 2, 200, _headers}, {:http_body, 2, reply}, {:http_end, 2}] = proxy_answer(2)
    assert %{"id" => 1, "result" => %{}} = Jason.decode!(reply)

    notification = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
    SandboxProxy.mcp(self(), 2, sandbox.id, %{"method" => "POST", "headers" => auth}, notification)
    assert [{:http_head, 2, 202, []}, {:http_end, 2}] = proxy_answer(2)

    SandboxProxy.mcp(self(), 2, sandbox.id, %{"method" => "POST", "headers" => auth}, "not json")
    assert [{:http_head, 2, 400, _headers}, _body, _end] = proxy_answer(2)

    SandboxProxy.mcp(self(), 2, sandbox.id, %{"method" => "GET", "headers" => auth}, "")
    assert [{:http_head, 2, 405, [{"allow", ["POST"]}]}, {:http_end, 2}] = proxy_answer(2)

    for headers <- [%{}, %{"authorization" => ["Bearer nope"]}, nil] do
      SandboxProxy.mcp(self(), 2, sandbox.id, %{"method" => "POST", "headers" => headers}, ping)
      assert [{:http_head, 2, 401, _headers}, _body, _end] = proxy_answer(2)
    end

    SandboxProxy.mcp(self(), 2, "sbx_elsewhere", %{"method" => "POST", "headers" => auth}, ping)
    assert [{:http_head, 2, 401, _headers}, _body, _end] = proxy_answer(2)
    refute_received _anything_else
  end
end
