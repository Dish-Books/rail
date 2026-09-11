defmodule Rail.Tools.Actions.OsProcessAliveTest do
  use ExUnit.Case, async: true

  alias Rail.Tools

  test "checks OS PID liveness" do
    self_pid = String.to_integer(System.pid())
    assert Tools.os_process_alive?(self_pid)

    refute Tools.os_process_alive?(999_999)
    refute Tools.os_process_alive?(nil)
    refute Tools.os_process_alive?(-1)
  end
end
