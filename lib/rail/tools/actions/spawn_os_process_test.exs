defmodule Rail.Tools.Actions.SpawnOsProcessTest do
  use ExUnit.Case, async: true

  alias Rail.Tools

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "spawn_os_process_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    wait_for_content = fn path ->
      Enum.reduce_while(1..200, "", fn _i, _acc ->
        content = if File.exists?(path), do: File.read!(path), else: ""

        if String.trim(content) == "" do
          Process.sleep(10)
          {:cont, content}
        else
          {:halt, content}
        end
      end)
    end

    %{tmp_dir: tmp_dir, wait_for_content: wait_for_content}
  end

  test "spawns a detached child and reports its OS PID", %{tmp_dir: tmp_dir} do
    out = Path.join(tmp_dir, "out.log")

    assert {:ok, port, os_pid} =
             Tools.spawn_os_process("/bin/sleep", ["2"], stdout_path: out, stderr_path: "#{out}.err")

    assert is_port(port)
    assert is_integer(os_pid) and os_pid > 0
    assert Tools.os_process_alive?(os_pid)

    Tools.terminate_os_process(os_pid, grace_period: 100)
  end

  test "redirects stdout and stderr to the given paths", %{tmp_dir: tmp_dir, wait_for_content: wait_for_content} do
    out = Path.join(tmp_dir, "streams.log")
    err = Path.join(tmp_dir, "streams.err")

    {:ok, _port, os_pid} =
      Tools.spawn_os_process("/bin/sh", ["-c", "echo to_stdout; echo to_stderr >&2; sleep 5"],
        stdout_path: out,
        stderr_path: err
      )

    assert wait_for_content.(out) =~ "to_stdout"
    assert wait_for_content.(err) =~ "to_stderr"

    Tools.terminate_os_process(os_pid, grace_period: 50)
  end

  test "passes extra environment through to the child", %{tmp_dir: tmp_dir, wait_for_content: wait_for_content} do
    out = Path.join(tmp_dir, "env.log")

    {:ok, _port, os_pid} =
      Tools.spawn_os_process("/bin/sh", ["-c", ~s(printf '%s' "$CUSTOM_VAR"; sleep 5)],
        env: %{"CUSTOM_VAR" => "spawned_value"},
        stdout_path: out,
        stderr_path: "#{out}.err"
      )

    assert wait_for_content.(out) =~ "spawned_value"

    Tools.terminate_os_process(os_pid, grace_period: 50)
  end

  test "runs the child in :cd when given", %{tmp_dir: tmp_dir, wait_for_content: wait_for_content} do
    out = Path.join(tmp_dir, "cwd.log")

    {:ok, _port, os_pid} =
      Tools.spawn_os_process("/bin/sh", ["-c", "pwd; sleep 5"],
        cd: tmp_dir,
        stdout_path: out,
        stderr_path: "#{out}.err"
      )

    reported = out |> wait_for_content.() |> String.trim()
    assert File.stat!(reported).inode == File.stat!(tmp_dir).inode

    Tools.terminate_os_process(os_pid, grace_period: 50)
  end
end
