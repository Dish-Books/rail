defmodule Rail.Tools.Utils.SandboxState do
  @moduledoc false

  alias Rail.Tools
  alias Rail.Tools.Clients.Docker
  alias Rail.Tools.Schemas.OsProcess

  @doc """
  Whether a process is still going: `:running`, `{:exited, exit_code, oom_killed?}`
  once its container has stopped, or `:gone` when there is nothing left to ask.

  A process beside Rail can only be asked whether it is alive, so it is never
  `:exited`. A Docker that cannot be reached reads as `:running`: a sandbox is not
  settled on the word of a socket that did not answer.
  """
  def sandbox_state(%OsProcess{runtime: :docker, container_id: id}) when is_binary(id) do
    case Docker.inspect_container(id) do
      {:ok, %{"State" => %{"Running" => true}}} -> :running
      {:ok, %{"State" => %{"ExitCode" => code} = state}} -> {:exited, code, state["OOMKilled"] == true}
      {:error, {:docker_api_error, 404, _body}} -> :gone
      {:error, _unreachable} -> :running
    end
  end

  def sandbox_state(%OsProcess{os_pid: os_pid}) when is_integer(os_pid) and os_pid > 0 do
    if Tools.os_process_alive?(os_pid), do: :running, else: :gone
  end

  def sandbox_state(%OsProcess{}), do: :gone
end
