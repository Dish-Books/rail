defmodule Rail.Tools.SandboxProxyDockerTest do
  # Claude Code itself, in a container with the real runner, reaching Claude only through Rail's socket and proxy.
  # Excluded by default: `make -C runner build`, then `mix test --include docker` with RAIL_DOCKER_CLAUDE_IMAGE naming an
  # image that has the pinned Claude Code at RAIL_DOCKER_CLAUDE (defaults: rail-sandbox:latest's).
  use Rail.DataCase, async: false

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.RunnerSocket
  alias Rail.Tools.Schemas.Backend
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Tools.Schemas.Sandbox

  @moduletag :docker
  @moduletag timeout: 180_000

  setup :set_mimic_global

  defmodule Upstream do
    @moduledoc false
    import Plug.Conn

    def init(test), do: test

    # Overloaded once, so the CLI's own retry is seen to go through the proxy too, then a streamed answer.
    def call(conn, test) do
      {:ok, body, conn} = read_body(conn, length: 64 * 1_048_576)
      count = :persistent_term.get({__MODULE__, :count})
      :ok = :counters.add(count, 1, 1)
      n = :counters.get(count, 1)
      send(test, {:upstream, conn.method, conn.request_path, conn.req_headers, Jason.decode!(body)})

      if n == 1 do
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(529, ~s({"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}))
      else
        stream(conn, Jason.decode!(body)["model"])
      end
    end

    defp stream(conn, model) do
      conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)

      events = [
        {"message_start",
         %{
           "type" => "message_start",
           "message" => %{
             "id" => "msg_1",
             "type" => "message",
             "role" => "assistant",
             "model" => model,
             "content" => [],
             "stop_reason" => nil,
             "stop_sequence" => nil,
             "usage" => %{"input_tokens" => 10, "output_tokens" => 1}
           }
         }},
        {"content_block_start",
         %{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "text", "text" => ""}}},
        {"content_block_delta",
         %{"type" => "content_block_delta", "index" => 0, "delta" => %{"type" => "text_delta", "text" => "PROXY"}}},
        {"content_block_delta",
         %{"type" => "content_block_delta", "index" => 0, "delta" => %{"type" => "text_delta", "text" => "_OK"}}},
        {"content_block_stop", %{"type" => "content_block_stop", "index" => 0}},
        {"message_delta",
         %{
           "type" => "message_delta",
           "delta" => %{"stop_reason" => "end_turn", "stop_sequence" => nil},
           "usage" => %{"output_tokens" => 5}
         }},
        {"message_stop", %{"type" => "message_stop"}}
      ]

      Enum.reduce(events, conn, fn {event, data}, conn ->
        Process.sleep(100)
        {:ok, conn} = chunk(conn, "event: #{event}\ndata: #{Jason.encode!(data)}\n\n")
        conn
      end)
    end
  end

  defmodule Socket do
    @moduledoc false
    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, state} = RunnerSocket.connect(conn.req_headers)
      conn |> WebSockAdapter.upgrade(RunnerSocket, state, timeout: 60_000) |> Plug.Conn.halt()
    end
  end

  setup do
    key = "DK#{System.unique_integer([:positive])}"

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Docker proxy",
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
        %{issue_id: issue.id, stage: :engineer, worktree_name: "w", worktree_path: "/work", scratch_path: "/s/#{key}"},
        project.id
      )
      |> Repo.insert!()

    {:ok, role} =
      Roles.create_role(system_scope(), project, %{
        stage: :engineer,
        cli: :claude,
        name: "Engineer",
        model: "claude-proxy",
        system_prompt: "x"
      })

    {:ok, run} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :running, started_at: DateTime.utc_now()})

    {:ok, backend} = Tools.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true", label: key})
    File.mkdir_p!(Backend.config_dir(backend))
    on_exit(fn -> File.rm_rf(Backend.config_dir(backend)) end)

    File.write!(
      Path.join(Backend.config_dir(backend), ".credentials.json"),
      Jason.encode!(%{"claudeAiOauth" => %{"accessToken" => "acct-token", "expiresAt" => 4_102_444_800_000}})
    )

    token = "sandbox-#{key}"
    mcp_token = "mcp-#{key}"

    sandbox =
      Repo.insert!(%Sandbox{
        task_id: task.id,
        engine: :docker,
        image: "x",
        volume: "v",
        status: :starting,
        token_hash: :crypto.hash(:sha256, token)
      })

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
        mcp_token_hash: :crypto.hash(:sha256, mcp_token)
      })

    stub(Rail.Git, :checkout_params, fn _project, _task -> {:ok, %{"path" => "/work", "branch" => "main"}} end)

    :persistent_term.put({Upstream, :count}, :counters.new(1, []))
    upstream = start_supervised!({Bandit, plug: {Upstream, self()}, ip: {127, 0, 0, 1}, port: 0}, id: :upstream)
    {:ok, {_ip, upstream_port}} = ThousandIsland.listener_info(upstream)
    socket = start_supervised!({Bandit, plug: Socket, ip: {0, 0, 0, 0}, port: 0}, id: :socket)
    {:ok, {_ip, socket_port}} = ThousandIsland.listener_info(socket)

    previous = Application.get_env(:rail, :claude_proxy)

    Application.put_env(:rail, :claude_proxy,
      upstream: "http://127.0.0.1:#{upstream_port}",
      req_options: [adapter: Req.Finch]
    )

    on_exit(fn -> Application.put_env(:rail, :claude_proxy, previous) end)

    %{mcp_token: mcp_token, sandbox: sandbox, socket_port: socket_port, token: token, turn: turn}
  end

  test "Claude Code runs a turn with no login, through the runner and Rail's proxy, retries and MCP included", %{
    mcp_token: mcp_token,
    sandbox: sandbox,
    socket_port: socket_port,
    token: token,
    turn: turn
  } do
    image = System.get_env("RAIL_DOCKER_CLAUDE_IMAGE", "rail-sandbox:latest")
    claude = System.get_env("RAIL_DOCKER_CLAUDE", "/home/rail/.local/bin/claude")
    {arch, 0} = System.cmd("docker", ["info", "--format", "{{.Architecture}}"], env: %{"RAIL_DOCKER_CLAUDE_IMAGE" => nil})
    arch = if String.trim(arch) in ["aarch64", "arm64"], do: "arm64", else: "amd64"
    runner = Path.join([Rail.runner_dir(), "linux-#{arch}", "rail-runner"])
    assert File.exists?(runner), "build the runner first: make -C runner build"

    {id, 0} =
      System.cmd(
        "docker",
        [
          "run",
          "-d",
          "--rm",
          "--user",
          "0:0",
          "--add-host",
          "host.docker.internal:host-gateway",
          "-v",
          "#{runner}:/opt/rail/rail-runner:ro",
          "-e",
          "RAIL_SANDBOX_URL=ws://host.docker.internal:#{socket_port}/sandbox/socket",
          "-e",
          "RAIL_SANDBOX_TOKEN=#{token}",
          "--entrypoint",
          "sh",
          image,
          "-c",
          "mkdir -p /work && git init -q /work && chown -R 1000:1000 /work && exec /opt/rail/rail-runner"
        ],
        env: %{"RAIL_DOCKER_CLAUDE_IMAGE" => nil}
      )

    id = String.trim(id)

    on_exit(fn ->
      System.cmd("docker", ["rm", "-f", id], stderr_to_stdout: true, env: %{"RAIL_DOCKER_CLAUDE_IMAGE" => nil})
    end)

    eventually(fn -> assert %Sandbox{status: :running} = Repo.reload!(sandbox) end, 30_000)
    conn = RunnerSocket.whereis(sandbox.id)

    mcp =
      Jason.encode!(%{
        "mcpServers" => %{
          "rail" => %{
            "type" => "http",
            "url" => "${RAIL_MCP_URL}",
            "headers" => %{"Authorization" => "Bearer ${RAIL_MCP_TOKEN}"}
          }
        }
      })

    exec = %{
      "argv" => [
        claude,
        "-p",
        "say hi",
        "--model",
        "claude-opus-4-1",
        "--output-format",
        "stream-json",
        "--verbose",
        "--mcp-config",
        mcp,
        "--strict-mcp-config"
      ],
      "env" => %{
        "CLAUDE_CONFIG_DIR" => Backend.sandbox_config_dir(),
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" => "1",
        "RAIL_MCP_TOKEN" => mcp_token,
        "PATH" => "/usr/local/bin:/usr/bin:/bin"
      },
      "cwd" => "/work",
      "files" => [],
      "claude" => true,
      "stdin" => nil,
      "stderr" => "separate"
    }

    RunnerSocket.follow(conn, turn.id, self(), 0, 0, exec)
    {out, err, code} = follow_to_exit(conn, turn.id)
    assert code == 0, "exit #{code}\n#{err}\n#{out}"

    events = out |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    assert %{"mcp_servers" => [%{"name" => "rail", "status" => "connected"}]} =
             Enum.find(events, &(&1["subtype"] == "init"))

    assert %{"result" => "PROXY_OK", "is_error" => false} = Enum.find(events, &(&1["type"] == "result"))

    requests = upstream_requests()
    assert length(requests) >= 2

    for {method, path, headers, _body} <- requests do
      assert {method, path} == {"POST", "/v1/messages"}
      headers = Map.new(headers)
      assert headers["authorization"] == "Bearer acct-token"
      assert headers["anthropic-beta"] =~ "oauth-2025-04-20"
      refute Map.has_key?(headers, "x-api-key")
    end
  end
end
