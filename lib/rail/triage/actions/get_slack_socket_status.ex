defmodule Rail.Triage.Actions.GetSlackSocketStatus do
  @moduledoc false

  alias Rail.Projects.Schemas.SlackWorkspace

  @doc """
  Where the workspace's Socket Mode connection stands: `:connected`,
  `:connecting`, `{:error, reason}` while Slack refuses it, or `:off` when no
  socket runs for it.
  """
  def get_slack_socket_status(%SlackWorkspace{id: id}) do
    case Registry.lookup(Rail.Triage.SocketRegistry, id) do
      [{_pid, status}] -> status
      [] -> :off
    end
  end
end
