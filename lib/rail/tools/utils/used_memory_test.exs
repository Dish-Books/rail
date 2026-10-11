defmodule Rail.Tools.Utils.UsedMemoryTest do
  use ExUnit.Case, async: true

  import Mimic
  import Rail.Tools.Utils.UsedMemory

  setup :verify_on_exit!

  test "reads what is in use as all of the machine's memory less what is available" do
    expect(File, :read, fn "/proc/meminfo" ->
      {:ok, "MemTotal:       16777216 kB\nMemFree:         1048576 kB\nMemAvailable:   11010048 kB\n"}
    end)

    assert used_memory() == 5.5
  end

  test "has nothing to say on a machine with no /proc" do
    expect(File, :read, fn "/proc/meminfo" -> {:error, :enoent} end)

    assert used_memory() == nil
  end
end
