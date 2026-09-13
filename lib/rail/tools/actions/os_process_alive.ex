defmodule Rail.Tools.Actions.OsProcessAlive do
  @moduledoc false

  @doc """
  Checks whether an OS process with the given PID is alive, via `kill -0 <pid>`.
  """
  def os_process_alive?(pid) when is_integer(pid) and pid > 0 do
    case System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true, env: %{}) do
      {_output, 0} -> true
      {_output, _code} -> false
    end

    # coveralls-ignore-start (defensive rescue if kill binary is missing)
  rescue
    _error ->
      false
      # coveralls-ignore-stop
  end

  def os_process_alive?(_other), do: false
end
