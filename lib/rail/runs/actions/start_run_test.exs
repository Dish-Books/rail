defmodule Rail.Runs.Actions.StartRunTest do
  use Rail.DataCase, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias Rail.Backends
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Runs
  alias Rail.Runs.FollowerSupervisor
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run
  alias Rail.Tools

  setup do
    scope = system_scope()
    unique = System.unique_integer([:positive])

    tmp_dir = Path.join(System.tmp_dir!(), "start_run_test_#{unique}")
    worktree_path = Path.join(tmp_dir, "worktree")
    scratch_path = Path.join(tmp_dir, "scratch")
    File.mkdir_p!(worktree_path)
    File.mkdir_p!(scratch_path)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    {:ok, workspace} =
      Projects.upsert_linear_workspace(scope, %{
        name: "Start Run Workspace #{unique}",
        external_id: "lin_ws_start_run_#{unique}",
        token: "lin_api_token_start_run_#{unique}",
        webhook_secret: "whsec_start_run_#{unique}"
      })

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Start Run Project #{unique}",
        github_repo: "org/start-run-#{unique}",
        github_installation_id: unique,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_start_run_#{unique}",
        linear_team_key: "SR#{unique}",
        default_branch: "main",
        clone_path: Path.join(tmp_dir, "clone")
      })

    # The executable is whatever the role's backend points at, so a test that
    # wants to spawn something else repoints this row before calling start_run.
    {:ok, backend} = Backends.create_backend(scope, %{name: :claude, executable_path: "/bin/sleep"})

    {:ok, role} =
      Roles.create_role(scope, project, %{
        backend_id: backend.id,
        stage: :engineer,
        name: "engineer role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the engineer."
      })

    {:ok, task} =
      %Task{id: UXID.generate!(prefix: "tsk")}
      |> Task.changeset(
        %{
          stage: :engineer,
          stage_state: :queued,
          worktree_name: "start-run-#{unique}",
          worktree_path: worktree_path,
          scratch_path: scratch_path
        },
        project.id
      )
      |> Repo.insert()

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :starting,
        started_at: DateTime.utc_now()
      })

    %{
      backend: backend,
      role_run: role_run,
      scratch_path: scratch_path,
      scope: scope,
      worktree_path: worktree_path
    }
  end

  test "spawns child, records runs row, sets os_pid and running status", %{role_run: role_run} do
    {:ok, run} =
      Runs.start_run(role_run, :stage, ["2"],
        allow_fun: fn pid ->
          Sandbox.allow(Repo, self(), pid)
          on_exit(fn -> FollowerSupervisor.stop_follower(pid) end)
        end
      )

    assert %Run{} = run
    assert run.role_run_id == role_run.id
    assert run.task_id == role_run.task_id
    assert run.status == :running
    assert is_integer(run.os_pid)
    assert run.os_pid > 0
    assert Tools.os_process_alive?(run.os_pid)

    Tools.terminate_os_process(run.os_pid, grace_period: 100)
  end

  test "writes the stream under the task's scratch directory, one file per role run", %{
    role_run: role_run,
    scratch_path: scratch_path
  } do
    {:ok, run} =
      Runs.start_run(role_run, :stage, ["2"],
        allow_fun: fn pid ->
          Sandbox.allow(Repo, self(), pid)
          on_exit(fn -> FollowerSupervisor.stop_follower(pid) end)
        end
      )

    assert run.stream_path == Path.join([scratch_path, "streams", "#{role_run.id}.ndjson"])
    assert File.exists?(run.stream_path)
    assert File.exists?("#{run.stream_path}.err")

    Tools.terminate_os_process(run.os_pid, grace_period: 100)
  end

  test "runs the child in the task's worktree and points it at the stream files", %{
    backend: backend,
    role_run: role_run,
    scope: scope,
    worktree_path: worktree_path
  } do
    {:ok, _backend} = Backends.update_backend(scope, backend, %{executable_path: "/bin/sh"})

    script = ~s(printf '{"cwd":"%s","stream":"%s"}\n' "$PWD" "$RAIL_STREAM")

    {:ok, run} =
      Runs.start_run(role_run, :stage, ["-c", script],
        allow_fun: fn pid ->
          Sandbox.allow(Repo, self(), pid)
          on_exit(fn -> FollowerSupervisor.stop_follower(pid) end)
        end
      )

    content =
      Enum.reduce_while(1..200, "", fn _i, _acc ->
        content = if File.exists?(run.stream_path), do: File.read!(run.stream_path), else: ""

        if content =~ run.stream_path do
          {:halt, content}
        else
          Process.sleep(10)
          {:cont, content}
        end
      end)

    assert content =~ run.stream_path
    assert content =~ Path.basename(worktree_path)

    Tools.terminate_os_process(run.os_pid, grace_period: 50)
  end

  test "with a missing backend binary reports error and settles the run", %{
    backend: backend,
    role_run: role_run,
    scope: scope
  } do
    missing_bin = "/path/to/nonexistent/cli_binary_xyz"
    {:ok, _backend} = Backends.update_backend(scope, backend, %{executable_path: missing_bin})

    result = Runs.start_run(role_run, :stage, ["--help"])

    assert {:error, {:missing_binary, ^missing_bin, %Run{status: :finished}}} = result

    reloaded_role_run = Repo.get!(RoleRun, role_run.id)
    assert reloaded_role_run.status == :finished
    assert reloaded_role_run.exit_code == -1
    assert reloaded_role_run.error =~ "No such CLI binary"
  end

  test "always starts a Follower under FollowerSupervisor", %{role_run: role_run} do
    {:ok, run} =
      Runs.start_run(role_run, :stage, ["2"],
        allow_fun: fn pid ->
          Sandbox.allow(Repo, self(), pid)
          on_exit(fn -> FollowerSupervisor.stop_follower(pid) end)
        end
      )

    assert run.status == :running
    follower_pid = Runs.get_follower_pid(run.id)
    assert is_pid(follower_pid)
    assert Process.alive?(follower_pid)

    Tools.terminate_os_process(run.os_pid, grace_period: 100)
  end

  test "calls opts[:allow_fun] with the Follower pid", %{role_run: role_run} do
    test_pid = self()

    {:ok, run} =
      Runs.start_run(role_run, :stage, ["2"],
        allow_fun: fn pid ->
          Sandbox.allow(Repo, test_pid, pid)
          on_exit(fn -> FollowerSupervisor.stop_follower(pid) end)
          send(test_pid, {:allowed, pid})
        end
      )

    assert_receive {:allowed, follower_pid}
    assert follower_pid == Runs.get_follower_pid(run.id)

    Tools.terminate_os_process(run.os_pid, grace_period: 100)
  end
end
