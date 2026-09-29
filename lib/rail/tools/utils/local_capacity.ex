defmodule Rail.Tools.Utils.LocalCapacity do
  @moduledoc false

  @gib 1024 ** 3

  @doc """
  The CPUs this machine lets Rail use and its memory in whole GB, read now, so a
  release built on one machine reports the one it runs on. Returns `{cpus, memory_gb}`.
  """
  def local_capacity do
    {cpus(), div(memory_bytes(), @gib)}
  end

  # Available rather than online: a cpuset limits what Rail can actually use.
  defp cpus do
    case :erlang.system_info(:logical_processors_available) do
      cpus when is_integer(cpus) -> cpus
      # coveralls-ignore-next-line (macOS, which cannot say what is available)
      :unknown -> :erlang.system_info(:logical_processors_online)
    end
  end

  defp memory_bytes do
    case File.read("/proc/meminfo") do
      {:ok, meminfo} ->
        [_line, kb] = Regex.run(~r/MemTotal:\s+(\d+) kB/, meminfo)
        String.to_integer(kb) * 1024

      # coveralls-ignore-start (macOS, which has no /proc)
      {:error, _no_proc} ->
        {bytes, 0} = System.cmd("sysctl", ["-n", "hw.memsize"], env: %{})
        bytes |> String.trim() |> String.to_integer()
        # coveralls-ignore-stop
    end
  end
end
