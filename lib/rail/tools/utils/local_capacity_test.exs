defmodule Rail.Tools.Utils.LocalCapacityTest do
  use ExUnit.Case, async: true

  import Rail.Tools.Utils.LocalCapacity

  test "reads the CPUs and whole GB of memory this machine has now" do
    {:ok, meminfo} = File.read("/proc/meminfo")
    [_line, kb] = Regex.run(~r/MemTotal:\s+(\d+) kB/, meminfo)

    assert local_capacity() ==
             {:erlang.system_info(:logical_processors_available), div(String.to_integer(kb) * 1024, 1024 ** 3)}
  end
end
