defmodule Rail.Tools.Actions.TerminateOsProcessTest do
  use ExUnit.Case, async: true

  import RailTest.Helpers, only: [eventually: 1]

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

  # How a Chrome hung at startup leaves a forked child behind that ignores TERM.
  test "a group kill takes the children, even one that ignores TERM" do
    child_pid_path = Path.join(System.tmp_dir!(), "terminate_group_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(child_pid_path) end)

    port =
      Port.open(
        {:spawn_executable, "/bin/sh"},
        [:binary, args: ["-c", ~s|sh -c "trap '' TERM; sleep 30" & echo $! > #{child_pid_path}; wait|]]
      )

    {:os_pid, pid} = Port.info(port, :os_pid)
    child = eventually(fn -> child_pid_path |> File.read!() |> String.trim() |> String.to_integer() end)
    assert Tools.os_process_alive?(child)

    assert Tools.terminate_os_process(pid, grace_period: 100, group: true) == :ok
    refute Tools.os_process_alive?(pid)
    eventually(fn -> refute Tools.os_process_alive?(child) end)
  end
end
