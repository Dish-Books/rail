defmodule Rail.Tools.Utils.LocalCapacityTest do
  use ExUnit.Case, async: true

  import Mimic
  import Rail.Tools.Utils.LocalCapacity

  setup :verify_on_exit!

  test "reads the CPUs and the whole GB of memory Linux reports" do
    expect(File, :read, fn "/proc/meminfo" -> {:ok, "MemTotal:       16777212 kB\nMemFree: 1 kB\n"} end)

    assert {cpus, 15} = local_capacity()

    assert cpus in [
             :erlang.system_info(:logical_processors_available),
             :erlang.system_info(:logical_processors_online)
           ]
  end

  # Whatever this machine is, it answers with what it has now.
  test "reads this machine's memory in whole GB" do
    assert {_cpus, memory_gb} = local_capacity()
    assert is_integer(memory_gb) and memory_gb >= 1
  end
end
