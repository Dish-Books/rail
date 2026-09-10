defmodule Rail.Runs.SpawnerTest do
  use Rail.DataCase, async: false

  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run
  alias Rail.Runs.Spawner

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "spawner_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    role_run =
      %RoleRun{}
      |> RoleRun.changeset(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: UXID.generate!(prefix: "rol"),
        status: :starting,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    on_exit(fn ->
      File.rm_rf(tmp_dir)
    end)

    %{role_run: role_run, tmp_dir: tmp_dir}
  end

  test "spawn_run/4 spawns child, records runs row, sets os_pid and running status", %{
    role_run: role_run,
    tmp_dir: tmp_dir
  } do
    stream_path = Path.join(tmp_dir, "test.ndjson")

    {:ok, run} =
      Spawner.spawn_run(
        role_run,
        :stage,
        ["/bin/sleep", "2"],
        stream_path: stream_path,
        skip_follower: true
      )

    assert %Run{} = run
    assert run.role_run_id == role_run.id
    assert run.task_id == role_run.task_id
    assert run.status == :running
    assert is_integer(run.os_pid)
    assert run.os_pid > 0
    assert Spawner.process_alive?(run.os_pid)

    # Clean up the sleeping child
    Spawner.terminate_os_process(run.os_pid, grace_period: 100)
  end

  test "spawn_run/4 accepts role_run_id binary", %{role_run: role_run, tmp_dir: tmp_dir} do
    stream_path = Path.join(tmp_dir, "test_id.ndjson")

    {:ok, run} =
      Spawner.spawn_run(
        role_run.id,
        :stage,
        ["/bin/echo", "hello"],
        stream_path: stream_path,
        skip_follower: true
      )

    assert run.role_run_id == role_run.id
    assert run.status == :running
    Process.sleep(50)
  end

  test "spawn_run/4 injects environment and streams output to files", %{
    role_run: role_run,
    tmp_dir: tmp_dir
  } do
    stream_path = Path.join(tmp_dir, "env_test.ndjson")
    scratch_dir = Path.join(tmp_dir, "scratch")
    File.mkdir_p!(scratch_dir)

    script =
      ~s(printf '{"stream":"%s","scratch":"%s","gh":"%s"}\n' "$AXIS_STREAM" "$AXIS_SCRATCH" "$GH_TOKEN")

    {:ok, run} =
      Spawner.spawn_run(
        role_run,
        :stage,
        ["/bin/sh", "-c", script],
        stream_path: stream_path,
        scratch_path: scratch_dir,
        gh_token: "gh_test_123",
        skip_follower: true
      )

    # Wait briefly for execution
    Process.sleep(150)

    assert File.exists?(stream_path)
    assert File.exists?("#{stream_path}.err")

    content = File.read!(stream_path)
    assert content =~ "gh_test_123"
    assert content =~ scratch_dir
    assert content =~ stream_path

    # Clean up child if still running
    Spawner.terminate_os_process(run.os_pid, grace_period: 50)
  end

  test "spawn_run/4 with missing binary reports error and settles run", %{
    role_run: role_run,
    tmp_dir: tmp_dir
  } do
    stream_path = Path.join(tmp_dir, "missing.ndjson")
    missing_bin = "/path/to/nonexistent/cli_binary_xyz"

    result =
      Spawner.spawn_run(
        role_run,
        :stage,
        [missing_bin, "--help"],
        stream_path: stream_path,
        skip_follower: true
      )

    assert {:error, {:missing_binary, ^missing_bin, %Run{status: :finished}}} = result

    # Verify role_run row in DB
    reloaded_role_run = Repo.get!(RoleRun, role_run.id)
    assert reloaded_role_run.status == :finished
    assert reloaded_role_run.exit_code == -1
    assert reloaded_role_run.error =~ "No such CLI binary"
  end

  test "spawn_run/4 starts Follower under FollowerSupervisor", %{
    role_run: role_run,
    tmp_dir: tmp_dir
  } do
    stream_path = Path.join(tmp_dir, "follow.ndjson")

    {:ok, run} =
      Spawner.spawn_run(
        role_run,
        :stage,
        ["/bin/sleep", "2"],
        stream_path: stream_path,
        skip_follower: false
      )

    assert run.status == :running
    follower_pid = Rail.Runs.get_follower_pid(run.id)
    assert is_pid(follower_pid)
    assert Process.alive?(follower_pid)

    Spawner.terminate_os_process(run.os_pid, grace_period: 100)
  end

  test "process_alive?/1 checks OS PID liveness" do
    self_pid = String.to_integer(System.pid())
    assert Spawner.process_alive?(self_pid)

    refute Spawner.process_alive?(999_999)
    refute Spawner.process_alive?(nil)
    refute Spawner.process_alive?(-1)
  end

  test "terminate_os_process/2 stops live child and handles dead PID" do
    # Spawn a sleeping child
    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["10"]])
    {:os_pid, pid} = Port.info(port, :os_pid)
    assert Spawner.process_alive?(pid)

    assert Spawner.terminate_os_process(pid, grace_period: 100) == :ok
    refute Spawner.process_alive?(pid)

    # Dead PID call returns :ok
    assert Spawner.terminate_os_process(999_999) == :ok
    assert Spawner.terminate_os_process(nil) == :ok
  end

  test "terminate_os_process/2 escalates to SIGKILL if child ignores SIGTERM" do
    port =
      Port.open(
        {:spawn_executable, "/bin/sh"},
        [:binary, args: ["-c", "trap '' TERM; sleep 30"]]
      )

    {:os_pid, pid} = Port.info(port, :os_pid)
    assert Spawner.process_alive?(pid)

    assert Spawner.terminate_os_process(pid, grace_period: 40) == :ok
    refute Spawner.process_alive?(pid)
  end

  test "spawn_run/4 supports opts[:executable], opts[:cd], opts[:state_dir], and opts[:credential_helper]", %{
    role_run: role_run,
    tmp_dir: tmp_dir
  } do
    helper_path = Path.join(tmp_dir, "fake_helper.sh")
    File.write!(helper_path, "#!/bin/sh\necho token\n")
    File.chmod!(helper_path, 0o755)

    custom_state_dir = Path.join(tmp_dir, "custom_state")
    File.mkdir_p!(custom_state_dir)

    {:ok, run} =
      Spawner.spawn_run(
        role_run,
        :stage,
        ["3"],
        executable: "/bin/sleep",
        cd: tmp_dir,
        state_dir: custom_state_dir,
        credential_helper: helper_path,
        skip_follower: true
      )

    assert run.status == :running
    assert run.stream_path =~ custom_state_dir
    Spawner.terminate_os_process(run.os_pid, grace_period: 50)
  end

  test "spawn_run/3 works with 3 arguments and resolves default executable with empty argv", %{
    role_run: role_run
  } do
    # When argv is empty, resolve_executable_and_args uses ArgvBuilder default executable path
    {:ok, run1} = Spawner.spawn_run(role_run, :stage, [], skip_follower: true)
    assert run1.status == :running
    Spawner.terminate_os_process(run1.os_pid, grace_period: 50)

    # 3-argument call without opts
    {:ok, run2} = Spawner.spawn_run(role_run, :stage, ["/bin/sleep", "1"])
    assert run2.status == :running
    follower_pid = Rail.Runs.get_follower_pid(run2.id)
    if is_pid(follower_pid), do: Rail.Runs.FollowerSupervisor.stop_follower(follower_pid)
    Spawner.terminate_os_process(run2.os_pid, grace_period: 50)
  end
end
