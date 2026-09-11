defmodule Rail.Runs.Actions.StartRunTest do
  use Rail.DataCase, async: true

  alias Rail.Backends.Schemas.Backend
  alias Rail.Runs
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run
  alias Rail.Tools

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "start_run_test_#{System.unique_integer([:positive])}")
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

  test "spawns child, records runs row, sets os_pid and running status", %{
    role_run: role_run,
    tmp_dir: tmp_dir
  } do
    stream_path = Path.join(tmp_dir, "test.ndjson")

    {:ok, run} =
      Runs.start_run(
        role_run,
        :stage,
        ["/bin/sleep", "2"],
        backend: %Backend{name: :claude, executable_path: "/usr/bin/true"},
        stream_path: stream_path,
        skip_follower: true
      )

    assert %Run{} = run
    assert run.role_run_id == role_run.id
    assert run.task_id == role_run.task_id
    assert run.status == :running
    assert is_integer(run.os_pid)
    assert run.os_pid > 0
    assert Tools.os_process_alive?(run.os_pid)

    # Clean up the sleeping child
    Tools.terminate_os_process(run.os_pid, grace_period: 100)
  end

  test "accepts a role_run_id binary", %{role_run: role_run, tmp_dir: tmp_dir} do
    stream_path = Path.join(tmp_dir, "test_id.ndjson")

    {:ok, run} =
      Runs.start_run(
        role_run.id,
        :stage,
        ["/bin/echo", "hello"],
        backend: %Backend{name: :claude, executable_path: "/usr/bin/true"},
        stream_path: stream_path,
        skip_follower: true
      )

    assert run.role_run_id == role_run.id
    assert run.status == :running
    Process.sleep(50)
  end

  test "injects environment and streams output to files", %{
    role_run: role_run,
    tmp_dir: tmp_dir
  } do
    stream_path = Path.join(tmp_dir, "env_test.ndjson")
    scratch_dir = Path.join(tmp_dir, "scratch")
    File.mkdir_p!(scratch_dir)

    script =
      ~s(printf '{"stream":"%s","scratch":"%s","gh":"%s"}\n' "$RAIL_STREAM" "$RAIL_SCRATCH" "$GH_TOKEN")

    {:ok, run} =
      Runs.start_run(
        role_run,
        :stage,
        ["/bin/sh", "-c", script],
        backend: %Backend{name: :claude, executable_path: "/usr/bin/true"},
        stream_path: stream_path,
        scratch_path: scratch_dir,
        gh_token: "gh_test_123",
        skip_follower: true
      )

    # Wait for the child to write its environment to the stream file.
    content =
      Enum.reduce_while(1..200, "", fn _i, _acc ->
        content = if File.exists?(stream_path), do: File.read!(stream_path), else: ""

        if content =~ "gh_test_123" and content =~ scratch_dir and content =~ stream_path do
          {:halt, content}
        else
          Process.sleep(10)
          {:cont, content}
        end
      end)

    assert File.exists?(stream_path)
    assert File.exists?("#{stream_path}.err")
    assert content =~ "gh_test_123"
    assert content =~ scratch_dir
    assert content =~ stream_path

    # Clean up child if still running
    Tools.terminate_os_process(run.os_pid, grace_period: 50)
  end

  test "with a missing binary reports error and settles the run", %{
    role_run: role_run,
    tmp_dir: tmp_dir
  } do
    stream_path = Path.join(tmp_dir, "missing.ndjson")
    missing_bin = "/path/to/nonexistent/cli_binary_xyz"

    result =
      Runs.start_run(
        role_run,
        :stage,
        [missing_bin, "--help"],
        backend: %Backend{name: :claude, executable_path: "/usr/bin/true"},
        stream_path: stream_path,
        skip_follower: true
      )

    assert {:error, {:missing_binary, ^missing_bin, %Run{status: :finished}}} = result

    reloaded_role_run = Repo.get!(RoleRun, role_run.id)
    assert reloaded_role_run.status == :finished
    assert reloaded_role_run.exit_code == -1
    assert reloaded_role_run.error =~ "No such CLI binary"
  end

  test "starts a Follower under FollowerSupervisor", %{role_run: role_run, tmp_dir: tmp_dir} do
    stream_path = Path.join(tmp_dir, "follow.ndjson")

    {:ok, run} =
      Runs.start_run(
        role_run,
        :stage,
        ["/bin/sleep", "2"],
        backend: %Backend{name: :claude, executable_path: "/usr/bin/true"},
        stream_path: stream_path,
        skip_follower: false
      )

    assert run.status == :running
    follower_pid = Runs.get_follower_pid(run.id)
    assert is_pid(follower_pid)
    assert Process.alive?(follower_pid)

    Tools.terminate_os_process(run.os_pid, grace_period: 100)
  end

  test "supports opts[:executable], opts[:cd], opts[:state_dir], and opts[:credential_helper]", %{
    role_run: role_run,
    tmp_dir: tmp_dir
  } do
    helper_path = Path.join(tmp_dir, "fake_helper.sh")
    File.write!(helper_path, "#!/bin/sh\necho token\n")
    File.chmod!(helper_path, 0o755)

    custom_state_dir = Path.join(tmp_dir, "custom_state")
    File.mkdir_p!(custom_state_dir)

    {:ok, run} =
      Runs.start_run(
        role_run,
        :stage,
        ["3"],
        backend: %Backend{name: :claude, executable_path: "/usr/bin/true"},
        executable: "/bin/sleep",
        cd: tmp_dir,
        state_dir: custom_state_dir,
        credential_helper: helper_path,
        skip_follower: true
      )

    assert run.status == :running
    assert run.stream_path =~ custom_state_dir
    Tools.terminate_os_process(run.os_pid, grace_period: 50)
  end

  test "works with 3 arguments and resolves the default executable with empty argv", %{
    role_run: role_run
  } do
    # When argv is empty, the configured backend path is used
    {:ok, _backend} =
      Rail.Backends.create_backend(Rail.Scope.for_system(), %{
        name: :claude,
        executable_path: "/bin/sleep"
      })

    {:ok, run1} =
      Runs.start_run(role_run, :stage, [],
        backend: %Backend{name: :claude, executable_path: "/usr/bin/true"},
        skip_follower: true
      )

    assert run1.status == :running
    Tools.terminate_os_process(run1.os_pid, grace_period: 50)

    {:ok, run2} =
      Runs.start_run(role_run, :stage, ["/bin/sleep", "1"],
        backend: %Backend{name: :claude, executable_path: "/usr/bin/true"},
        skip_follower: false
      )

    assert run2.status == :running
    follower_pid = Runs.get_follower_pid(run2.id)
    if is_pid(follower_pid), do: Rail.Runs.FollowerSupervisor.stop_follower(follower_pid)
    Tools.terminate_os_process(run2.os_pid, grace_period: 50)
  end
end
