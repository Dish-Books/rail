defmodule Rail.Projects.Actions.UpdateSlackWorkspace do
  @moduledoc false

  import Rail.Projects.Utils.IdentifySlackWorkspace

  alias Rail.Projects.Schemas.SlackWorkspace
  alias Rail.Repo

  @doc """
  Saves the workspace, asking Slack whose bot token it is when that changed,
  and announces it on `"slack_workspaces"` so its socket reopens.
  """
  def update_slack_workspace(_scope, %SlackWorkspace{} = workspace, attrs) do
    with {:ok, changeset} <- workspace |> SlackWorkspace.changeset(attrs) |> identify_slack_workspace(),
         {:ok, workspace} <- Repo.update(changeset) do
      Phoenix.PubSub.broadcast(Rail.PubSub, "slack_workspaces", {:slack_workspace_changed, workspace.id})
      {:ok, workspace}
    end
  end
end
