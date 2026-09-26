defmodule Rail.Projects.Actions.CreateSlackWorkspace do
  @moduledoc false

  import Rail.Projects.Utils.IdentifySlackWorkspace

  alias Rail.Projects.Schemas.SlackWorkspace
  alias Rail.Repo

  @doc """
  Saves a workspace once Slack has said whose bot token it is, and announces it
  on `"slack_workspaces"` so its socket opens.
  """
  def create_slack_workspace(_scope, attrs) do
    with {:ok, changeset} <- %SlackWorkspace{} |> SlackWorkspace.changeset(attrs) |> identify_slack_workspace(),
         {:ok, workspace} <- Repo.insert(changeset) do
      Phoenix.PubSub.broadcast(Rail.PubSub, "slack_workspaces", {:slack_workspace_changed, workspace.id})
      {:ok, workspace}
    end
  end
end
