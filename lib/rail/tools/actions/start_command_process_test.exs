defmodule Rail.Tools.Actions.StartCommandProcessTest do
  use Rail.DataCase, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.FollowerSupervisor
  alias Rail.Tools.Schemas.OsProcess

  # These tests are about the spawn itself, so they run real children.
  @moduletag :real_spawn

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "start_command_test_#{System.unique_integer([:positive])}")
    worktree_path = Path.join(tmp_dir, "worktree")
    File.mkdir_p!(worktree_path)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    {:ok, backend} = Tools.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    project =
      %Project{}
      |> Project.changeset(%{
        name: "Command Project",
        github_repo: "org/command-#{System.unique_integer([:positive])}",
        github_installation_id: System.unique_integer([:positive]),
        linear_team_key: "CMD",
        default_branch: "main",
        clone_path: Path.join(tmp_dir, "clone")
      })
      |> Repo.insert!()

    {:ok, role} =
      Roles.create_role(system_scope(), project, %{
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
        external_id: "lin_command_#{System.unique_integer([:positive])}",
        identifier: "CMD-1",
        title: "Command Issue",
        state: :backlog
      })
      |> Repo.insert!()

    task =
      %Task{}
      |> Task.changeset(
        %{
          issue_id: issue.id,
          stage: :engineer,
          worktree_name: "cmd-1",
          worktree_path: worktree_path,
          scratch_path: Path.join(tmp_dir, "scratch"),
          worktree_slot: 4
        },
        project.id
      )
      |> Repo.insert!()

    {:ok, run} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :running, started_at: DateTime.utc_now()})

    %{run: run, worktree_path: worktree_path}
  end

  test "runs the command in the worktree with its ports, and records how it exited", %{
    run: run,
    worktree_path: worktree_path
  } do
    expect(FollowerSupervisor, :start_follower, fn _os_process, [port: _port] -> {:ok, self()} end)

    assert {:ok, %OsProcess{kind: :setup, status: :running, command: "pwd; echo $RAIL_PORT_BASE; exit 3"} = os_process} =
             Tools.start_command_process(run, :setup, "pwd; echo $RAIL_PORT_BASE; exit 3")

    eventually(fn -> assert File.read(OsProcess.exit_path(os_process)) == {:ok, "3\n"} end)

    assert {:ok, output} = File.read(os_process.stream_path)
    assert output =~ Path.basename(worktree_path)
    assert output =~ "20400"
  end

  test "is given a deadline as far off as its timeout, and the commit it runs against", %{run: run} do
    expect(FollowerSupervisor, :start_follower, fn _os_process, _opts -> {:ok, self()} end)

    assert {:ok, %OsProcess{started_at: started_at, deadline_at: deadline_at} = os_process} =
             Tools.start_command_process(run, :ci, "sleep 0.1", timeout_ms: 90_000, head_sha: "abc123")

    assert DateTime.diff(deadline_at, started_at, :millisecond) == 90_000
    assert %OsProcess{kind: :ci, head_sha: "abc123"} = os_process
    eventually(fn -> assert File.exists?(OsProcess.exit_path(os_process)) end)
  end

  test "a worktree that is not there fails the process before anything runs", %{
    run: run,
    worktree_path: worktree_path
  } do
    File.rm_rf!(worktree_path)
    reject(FollowerSupervisor, :start_follower, 2)

    assert {:error, {:bad_cwd, ^worktree_path}} = Tools.start_command_process(run, :setup, "true")
    assert [%OsProcess{status: :failed}] = Tools.list_os_processes(run_id: run.id, kind: :setup)
  end

  test "a command gone before its pid could be read is still followed to its exit", %{run: run} do
    expect(Tools, :spawn_os_process, fn _executable, _args, opts ->
      File.write!(Keyword.fetch!(opts, :env)["__RAIL_EXIT_PATH"], "0\n")
      {:error, :no_os_pid}
    end)

    expect(FollowerSupervisor, :start_follower, fn %OsProcess{os_pid: nil}, [port: nil] -> {:ok, self()} end)

    assert {:ok, %OsProcess{status: :running, os_pid: nil} = os_process} =
             Tools.start_command_process(run, :setup, "true")

    assert File.read(OsProcess.exit_path(os_process)) == {:ok, "0\n"}
  end
end
