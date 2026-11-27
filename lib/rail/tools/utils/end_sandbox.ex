defmodule Rail.Tools.Utils.EndSandbox do
  @moduledoc false

  alias Rail.Tools
  alias Rail.Tools.Clients.Docker
  alias Rail.Tools.RunnerSocket
  alias Rail.Tools.Schemas.OsProcess

  @kill_grace_ms 500

  @doc """
  Stops whatever a process is running in: its OS process beside Rail, or its
  container. `:grace_period` is how long it has after SIGTERM before SIGKILL, in
  milliseconds; Docker counts in whole seconds, so it is rounded up there.
  """
  # A process in a task's sandbox is signalled, not its container, which is the task's; KILL follows the grace.
  def end_sandbox(%OsProcess{id: id, sandbox_id: sandbox_id}, opts) when is_binary(sandbox_id) do
    RunnerSocket.signal(sandbox_id, id, "TERM")

    case RunnerSocket.whereis(sandbox_id) do
      conn when is_pid(conn) ->
        Process.send_after(conn, {:signal, id, "KILL"}, Keyword.get(opts, :grace_period, @kill_grace_ms))

      nil ->
        :ok
    end

    :ok
  end

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
