defmodule Rail.Tools.Utils.EndSandbox do
  @moduledoc false

  alias Rail.Tools
  alias Rail.Tools.Clients.Docker
  alias Rail.Tools.Schemas.OsProcess

  @kill_grace_ms 500

  @doc """
  Stops whatever a process is running in: its OS process beside Rail, or its
  container. `:grace_period` is how long it has after SIGTERM before SIGKILL, in
  milliseconds; Docker counts in whole seconds, so it is rounded up there.
  """
  def end_sandbox(%OsProcess{runtime: :docker, container_id: id}, opts) when is_binary(id) do
    seconds = opts |> Keyword.get(:grace_period, @kill_grace_ms) |> Kernel./(1000) |> Float.ceil() |> trunc()
    _stopped = Docker.stop_container(id, seconds)
    :ok
  end

  def end_sandbox(%OsProcess{os_pid: os_pid}, opts) when is_integer(os_pid) and os_pid > 0 do
    Tools.terminate_os_process(os_pid, Keyword.take(opts, [:grace_period, :group]))
  end

  def end_sandbox(%OsProcess{}, _opts), do: :ok
end
