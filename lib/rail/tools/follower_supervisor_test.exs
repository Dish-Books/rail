defmodule Rail.Tools.FollowerSupervisorTest do
  use Rail.DataCase, async: true

  import Rail.Tools.Utils.GetFollowerPid

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Projects.Schemas.Project
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.FollowerSupervisor
  alias Rail.Tools.Schemas.OsProcess

  # The supervisor hands over a real port.
  @moduletag :real_spawn

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "supervisor_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    # The Follower reads the stream in its backend's format, and the backend comes
    # off the run's role.
    {:ok, backend} =
      Tools.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    project =
      %Project{}
      |> Project.changeset(%{
        name: "Supervisor Project",
        github_repo: "org/supervisor-#{System.unique_integer([:positive])}",
        github_installation_id: System.unique_integer([:positive]),
        linear_team_key: "SUP",
        default_branch: "main",
        clone_path: Path.join(tmp_dir, "clone")
      })
      |> Repo.insert!()

    {:ok, role} =
      Roles.create_role(system_scope(), project, %{
        backend_id: backend.id,
        stage: :engineer,
        name: "supervisor role",
        model: "claude-opus-5-5",
        system_prompt: "You are the engineer."
      })

    run =
      %Run{}
      |> Run.changeset(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()
      |> Repo.preload(role: :backend)

    stream_path = Path.join(tmp_dir, "sup_test.ndjson")
    File.write!(stream_path, "")
    File.write!("#{stream_path}.err", "")

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: stream_path,
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    on_exit(fn ->
      File.rm_rf(tmp_dir)
    end)

    %{run: run, os_process: os_process, stream_path: stream_path}
  end

  test "starts and stops follower children under supervision", %{
    run: run,
    os_process: os_process
  } do
    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["10"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    # Nothing here is about what the Follower reads, so its first tick, which
    # reads the row, is put past the test: this Follower has no sandbox.
    {:ok, follower_pid} =
      FollowerSupervisor.start_follower(%{os_process | os_pid: pid, run: run}, tail_interval_ms: 60_000)

    assert is_pid(follower_pid)
    assert Process.alive?(follower_pid)

    # Lookup in registry
    assert get_follower_pid(os_process.id) == follower_pid

    # Stop child via supervisor
    assert FollowerSupervisor.stop_follower(follower_pid) == :ok
    refute Process.alive?(follower_pid)
    Process.sleep(10)
    assert get_follower_pid(os_process.id) == nil

    Tools.terminate_os_process(pid, grace_period: 50)
  end

  test "hands a spawned port to the follower and unlinks it from the caller", %{
    run: run,
    os_process: os_process,
    stream_path: stream_path
  } do
    {:ok, port, os_pid} = Tools.spawn_os_process("/bin/sleep", ["10"], stdout_path: stream_path)

    {:ok, follower_pid} =
      FollowerSupervisor.start_follower(%{os_process | os_pid: os_pid, run: run}, port: port, tail_interval_ms: 60_000)

    assert Port.info(port, :connected) == {:connected, follower_pid}
    {:links, links} = Process.info(self(), :links)
    refute port in links

    FollowerSupervisor.stop_follower(follower_pid)
    Tools.terminate_os_process(os_pid, grace_period: 50)
  end
end
