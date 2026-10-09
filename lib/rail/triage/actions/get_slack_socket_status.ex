defmodule Rail.Triage.Actions.GetSlackSocketStatus do
  @moduledoc false

  alias Rail.Projects.Schemas.SlackWorkspace

  @doc """
  Where the workspace's Socket Mode connection stands, as `%{status: status, last_frame_at: at}`.
  The status is `:connected`, `:connecting`, `{:error, reason}` while Slack refuses it, or `:off`
  when no socket runs for it; `last_frame_at` is when Slack last sent anything down it.
  """
  def get_slack_socket_status(%SlackWorkspace{id: id}) do
    case Registry.lookup(Rail.Triage.SocketRegistry, id) do
      [{_pid, %{status: _status, last_frame_at: _at} = socket}] -> socket
      [] -> %{status: :off, last_frame_at: nil}
    end
  end
end
