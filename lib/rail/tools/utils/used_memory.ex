defmodule Rail.Tools.Utils.UsedMemory do
  @moduledoc false

  @doc """
  The memory this machine has in use right now, in GB to a tenth: all of it less
  what the kernel says is available, so the page cache it would give back is not
  counted. A container reads its host's, so under Docker it is still the machine's.
  `nil` where there is no `/proc` to read it from.
  """
  def used_memory do
    with {:ok, meminfo} <- File.read("/proc/meminfo"),
         [_total, total] <- Regex.run(~r/MemTotal:\s+(\d+) kB/, meminfo),
         [_available, available] <- Regex.run(~r/MemAvailable:\s+(\d+) kB/, meminfo) do
      Float.round((String.to_integer(total) - String.to_integer(available)) / 1024 ** 2, 1)
    else
      _unreadable -> nil
    end
  end
end
