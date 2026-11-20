defmodule Rail.Support.Actions.UpdateIntercomWorkspace do
  @moduledoc false

  import Rail.Support.Utils.IdentifyIntercomWorkspace

  alias Rail.Repo
  alias Rail.Support.Schemas.IntercomWorkspace

  @doc """
  Edits a workspace's name and secrets, checking a new token against Intercom. The project stays as created.
  """
  def update_intercom_workspace(_scope, %IntercomWorkspace{} = workspace, attrs) do
    with {:ok, changeset} <- workspace |> IntercomWorkspace.changeset(attrs) |> identify_intercom_workspace(),
         {:ok, workspace} <- Repo.update(changeset) do
      Phoenix.PubSub.broadcast(Rail.PubSub, "intercom_workspaces", {:intercom_workspace_changed, workspace.id})
      {:ok, workspace}
    end
  end
end
