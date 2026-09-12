defmodule Rail.Runs.Utils.GetFollowerPidTest do
  use Rail.DataCase, async: true

  import Rail.Runs.Utils.GetFollowerPid

  alias Rail.Projects.Schemas.Project
  alias Rail.Roles
  alias Rail.Runs
  alias Rail.Runs.FollowerSupervisor
  alias Rail.Runs.Schemas.OsProcess

  test "returns nil when no follower is registered" do
    assert is_nil(get_follower_pid("osp_nonexistent"))
  end

  test "finds a live follower by its os process id" do
    tmp_dir = Path.join(System.tmp_dir!(), "get_follower_pid_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    stream_path = Path.join(tmp_dir, "stream.ndjson")
    File.write!(stream_path, "")

    # The Follower reads the stream format off the run's role, so the run needs a
    # real role behind it.
    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    project =
      %Project{}
      |> Project.changeset(%{
        name: "Follower Pid Project",
        github_repo: "org/follower-pid-#{System.unique_integer([:positive])}",
        github_installation_id: System.unique_integer([:positive]),
        linear_team_id: "team_follower_pid",
        linear_team_key: "FPD",
        default_branch: "main",
        clone_path: Path.join(tmp_dir, "clone")
      })
      |> Repo.insert!()

    {:ok, role} =
      Roles.create_role(system_scope(), project, %{
        backend_id: backend.id,
        stage: :engineer,
        name: "follower pid role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the engineer."
      })

    {:ok, run} =
      Runs.create_run(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    run = Repo.preload(run, role: :backend)

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: stream_path,
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, follower_pid} =
      FollowerSupervisor.start_follower(%{os_process | run: run})

    on_exit(fn -> FollowerSupervisor.stop_follower(follower_pid) end)

    assert get_follower_pid(os_process.id) == follower_pid
    assert get_follower_pid(os_process.id) == follower_pid
  end
end
