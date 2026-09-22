defmodule Rail.Tools.Actions.TerminateOsProcessTest do
  use ExUnit.Case, async: true

  import RailTest.Helpers

  alias Rail.Tools

  test "stops a live child and handles a dead PID" do
    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["10"]])
    {:os_pid, pid} = Port.info(port, :os_pid)
    assert Tools.os_process_alive?(pid)

    assert Tools.terminate_os_process(pid, grace_period: 100) == :ok
    refute Tools.os_process_alive?(pid)

    assert Tools.terminate_os_process(999_999) == :ok
    assert Tools.terminate_os_process(nil) == :ok
  end

  test "escalates to SIGKILL if the child ignores SIGTERM" do
    port =
      Port.open(
        {:spawn_executable, "/bin/sh"},
        [:binary, args: ["-c", "trap '' TERM; sleep 30"]]
      )

    {:os_pid, pid} = Port.info(port, :os_pid)
    assert Tools.os_process_alive?(pid)

    assert Tools.terminate_os_process(pid, grace_period: 40) == :ok
    refute Tools.os_process_alive?(pid)
  end

  test "stops everything in the group a leader started when asked to" do
    child_pid_path = Path.join(System.tmp_dir!(), "terminate_group_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(child_pid_path) end)

    port =
      Port.open(
        {:spawn_executable, "/usr/bin/perl"},
        [
          :binary,
          args: ["-e", "setpgrp(0, 0); exec @ARGV", "/bin/sh", "-c", "sleep 30 & echo $! > #{child_pid_path}; wait"]
        ]
      )

    {:os_pid, pid} = Port.info(port, :os_pid)

    child_pid =
      eventually(fn ->
        assert {:ok, content} = File.read(child_pid_path)
        assert {child_pid, "\n"} = Integer.parse(content)
        child_pid
      end)

    assert Tools.terminate_os_process(pid, group: true, grace_period: 200) == :ok
    eventually(fn -> refute Tools.os_process_alive?(child_pid) end)
  end
end
