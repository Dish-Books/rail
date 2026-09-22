defmodule Rail.Tools.Actions.TerminateOsProcessTest do
  use ExUnit.Case, async: true

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
end
