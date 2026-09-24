defmodule Rail.Tools.Actions.TerminateOsProcess do
  @moduledoc false

  alias Rail.Tools

  @poll_interval_ms 20
  @kill_grace_ms 500

  @doc """
  Terminates an OS process with SIGTERM, waiting up to `:grace_period`
  milliseconds, and escalates to SIGKILL if it is still alive.

  `group: true` signals the process group it leads, which a port's child does,
  and then kills whatever in the group outlived it.
  """
  def terminate_os_process(pid, opts) when is_integer(pid) and pid > 0 do
    group? = Keyword.get(opts, :group, false)
    target = if group?, do: "-#{pid}", else: to_string(pid)
    kill(target, "TERM")

    if !wait_until_dead(pid, Keyword.get(opts, :grace_period, @kill_grace_ms)) do
      kill(target, "KILL")
      wait_until_dead(pid, @kill_grace_ms)
    end

    # A forked child stuck on a lock ignores TERM, and nothing is left waiting on it.
    if group?, do: kill(target, "KILL")

    :ok
  end

  def terminate_os_process(_other, _opts), do: :ok

  defp kill(target, signal) do
    System.cmd("kill", ["-#{signal}", "--", target], stderr_to_stdout: true, env: %{})
    # coveralls-ignore-start (defensive rescue if kill fails)
  rescue
    _error ->
      :ok
      # coveralls-ignore-stop
  end

  defp wait_until_dead(pid, timeout_ms) do
    wait_until(pid, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp wait_until(pid, deadline) do
    cond do
      not Tools.os_process_alive?(pid) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(@poll_interval_ms)
        wait_until(pid, deadline)
    end
  end
end
