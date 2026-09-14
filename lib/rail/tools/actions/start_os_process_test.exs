defmodule Rail.Tools.Actions.StartOsProcessTest do
  use Rail.DataCase, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.FollowerSupervisor
  alias Rail.Tools.Schemas.Backend
  alias Rail.Tools.Schemas.OsProcess

  # These tests are about the spawn itself, so they run real children.
  @moduletag :real_spawn

  setup do
    scope = system_scope()
    unique = System.unique_integer([:positive])

    tmp_dir = Path.join(System.tmp_dir!(), "start_run_test_#{unique}")
    worktree_path = Path.join(tmp_dir, "worktree")
    scratch_path = Path.join(tmp_dir, "scratch")
    File.mkdir_p!(worktree_path)
    File.mkdir_p!(scratch_path)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Start Run Project #{unique}",
        github_repo: "org/start-run-#{unique}",
        github_installation_id: unique,
        linear_workspace: %{
          name: "Start Run Workspace #{unique}",
          external_id: "lin_ws_start_run_#{unique}",
          token: "lin_api_token_start_run_#{unique}",
          webhook_secret: "whsec_start_run_#{unique}"
        },
        linear_team_key: "SR#{unique}",
        default_branch: "main",
        clone_path: Path.join(tmp_dir, "clone")
      })

    # The executable is whatever the role's backend points at, so a test that
    # wants to spawn something else repoints this row before calling start_os_process.
    {:ok, backend} = Tools.create_backend(scope, %{name: :claude, executable_path: "/bin/sleep"})

    {:ok, role} =
      Roles.create_role(scope, project, %{
        backend_id: backend.id,
        stage: :engineer,
        name: "engineer role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the engineer."
      })

    issue =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project.id,
        external_id: "lin_start_run_#{unique}",
        identifier: "SR#{unique}-1",
        title: "Start Run Issue",
        state: :backlog
      })
      |> Repo.insert!()

    {:ok, task} =
      %Task{id: UXID.generate!(prefix: "tsk")}
      |> Task.changeset(
        %{
          issue_id: issue.id,
          stage: :engineer,
          worktree_name: "start-run-#{unique}",
          worktree_path: worktree_path,
          scratch_path: scratch_path
        },
        project.id
      )
      |> Repo.insert()

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :starting,
        started_at: DateTime.utc_now()
      })

    %{
      backend: backend,
      run: run,
      scratch_path: scratch_path,
      scope: scope,
      worktree_path: worktree_path
    }
  end

  test "spawns child, records runs row, sets os_pid and running status", %{run: run} do
    expect(FollowerSupervisor, :start_follower, fn _os_process, _opts -> {:ok, self()} end)

    {:ok, os_process} = Tools.start_os_process(run, ["2"])

    assert %OsProcess{} = os_process
    assert os_process.run_id == run.id
    assert os_process.task_id == run.task_id
    assert os_process.status == :running
    assert is_integer(os_process.os_pid)
    assert os_process.os_pid > 0
    assert Tools.os_process_alive?(os_process.os_pid)

    Tools.terminate_os_process(os_process.os_pid, grace_period: 100)
  end

  test "gives a role with MCP tools a run token in its environment, and records only its hash", %{
    run: run,
    scope: scope
  } do
    {:ok, role} = Roles.get_role(id: run.role_id)
    {:ok, _role} = Roles.update_role(scope, role, %{mcp_tools: ["linear__*"]})
    test_pid = self()

    expect(Tools, :spawn_os_process, fn _executable, _args, opts ->
      send(test_pid, {:env, Keyword.fetch!(opts, :env)})
      {:ok, nil, 4242}
    end)

    expect(FollowerSupervisor, :start_follower, fn _os_process, _opts -> {:ok, self()} end)

    assert {:ok, %OsProcess{id: os_process_id}} = Tools.start_os_process(run, ["2"])
    assert_received {:env, %{"RAIL_MCP_TOKEN" => token}}

    hash = :crypto.hash(:sha256, token)
    assert %OsProcess{mcp_token_hash: ^hash} = Repo.get!(OsProcess, os_process_id)
  end

  test "spawns a role without MCP tools with no token", %{run: run} do
    test_pid = self()

    expect(Tools, :spawn_os_process, fn _executable, _args, opts ->
      send(test_pid, {:env, Keyword.fetch!(opts, :env)})
      {:ok, nil, 4243}
    end)

    expect(FollowerSupervisor, :start_follower, fn _os_process, _opts -> {:ok, self()} end)

    assert {:ok, %OsProcess{mcp_token_hash: nil}} = Tools.start_os_process(run, ["2"])
    assert_received {:env, env}
    refute Map.has_key?(env, "RAIL_MCP_TOKEN")
  end

  test "writes the stream under the task's scratch directory, one file per run", %{
    run: run,
    scratch_path: scratch_path
  } do
    expect(FollowerSupervisor, :start_follower, fn _os_process, _opts -> {:ok, self()} end)

    {:ok, os_process} = Tools.start_os_process(run, ["2"])

    assert os_process.stream_path == Path.join([scratch_path, "streams", "#{run.id}.ndjson"])
    assert File.exists?(os_process.stream_path)
    assert File.exists?("#{os_process.stream_path}.err")

    Tools.terminate_os_process(os_process.os_pid, grace_period: 100)
  end

  test "runs the child in the task's worktree and points it at the stream files", %{
    backend: backend,
    run: run,
    scope: scope,
    worktree_path: worktree_path
  } do
    {:ok, _backend} = Tools.update_backend(scope, backend, %{executable_path: "/bin/sh"})

    script = ~s(printf '{"cwd":"%s"}\n' "$PWD")

    expect(FollowerSupervisor, :start_follower, fn _os_process, _opts -> {:ok, self()} end)

    {:ok, os_process} = Tools.start_os_process(run, ["-c", script])

    content =
      Enum.reduce_while(1..200, "", fn _i, _acc ->
        content = if File.exists?(os_process.stream_path), do: File.read!(os_process.stream_path), else: ""

        if content =~ Path.basename(worktree_path) do
          {:halt, content}
        else
          Process.sleep(10)
          {:cont, content}
        end
      end)

    assert content =~ Path.basename(worktree_path)

    Tools.terminate_os_process(os_process.os_pid, grace_period: 50)
  end

  test "runs the child as the account in the backend's config directory", %{
    backend: backend,
    run: run,
    scope: scope
  } do
    {:ok, backend} = Tools.update_backend(scope, backend, %{executable_path: "/bin/sh"})
    config_dir = Backend.config_dir(backend)

    expect(FollowerSupervisor, :start_follower, fn _os_process, _opts -> {:ok, self()} end)

    {:ok, os_process} = Tools.start_os_process(run, ["-c", ~s(printf '%s\n' "$CLAUDE_CONFIG_DIR")])

    content =
      Enum.reduce_while(1..200, "", fn _i, _acc ->
        content = File.read!(os_process.stream_path)

        if content =~ config_dir do
          {:halt, content}
        else
          Process.sleep(10)
          {:cont, content}
        end
      end)

    assert content == config_dir <> "\n"

    Tools.terminate_os_process(os_process.os_pid, grace_period: 50)
  end

  test "with a missing backend binary reports error and settles the run", %{
    backend: backend,
    run: run,
    scope: scope
  } do
    missing_bin = "/path/to/nonexistent/cli_binary_xyz"
    {:ok, _backend} = Tools.update_backend(scope, backend, %{executable_path: missing_bin})

    result = Tools.start_os_process(run, ["--help"])

    assert {:error, {:spawn_failed, {:missing_binary, ^missing_bin, %OsProcess{status: :finished}}, %Run{}}} =
             result

    reloaded_run = Repo.get!(Run, run.id)
    assert reloaded_run.status == :finished
    assert reloaded_run.exit_code == -1
    assert reloaded_run.error =~ "No such CLI binary"
  end

  test "a Follower that will not start fails the run with the reason", %{run: run} do
    expect(FollowerSupervisor, :start_follower, fn _os_process, _opts -> {:error, :no_follower} end)

    assert {:error, {:spawn_failed, :no_follower, %Run{error: "Failed to spawn runner: :no_follower"}}} =
             Tools.start_os_process(run, ["2"])

    %OsProcess{os_pid: os_pid} = Repo.get_by!(OsProcess, run_id: run.id)
    Tools.terminate_os_process(os_pid, grace_period: 100)
  end

  test "hands the spawned port and stream to a Follower", %{backend: %Backend{id: backend_id}, run: run} do
    test_pid = self()

    expect(FollowerSupervisor, :start_follower, fn followed, opts ->
      send(test_pid, {:followed, followed, opts})
      {:ok, test_pid}
    end)

    {:ok, os_process} = Tools.start_os_process(run, ["2"])

    # Everything the Follower needs rides on the row it is handed.
    assert_receive {:followed, followed, opts}
    assert followed.id == os_process.id
    assert followed.stream_path == os_process.stream_path
    assert followed.os_pid == os_process.os_pid
    assert followed.run.id == run.id
    assert followed.run.role.backend.id == backend_id
    assert is_port(opts[:port])

    Tools.terminate_os_process(os_process.os_pid, grace_period: 100)
  end
end
