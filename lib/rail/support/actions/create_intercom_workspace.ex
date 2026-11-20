defmodule Rail.Support.Actions.CreateIntercomWorkspace do
  @moduledoc false

  import Rail.Support.Utils.IdentifyIntercomWorkspace

  alias Ecto.Multi
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Support.Schemas.IntercomWorkspace
  alias Rail.Support.Workers.BackfillIntercomWorkspace

  @doc """
  Saves the workspace under the app id its token belongs to, and starts importing every conversation.
  """
  def create_intercom_workspace(_scope, %Project{} = project, attrs) do
    with {:ok, changeset} <- project |> IntercomWorkspace.create_changeset(attrs) |> identify_intercom_workspace(),
         {:ok, %{workspace: workspace}} <-
           Multi.new()
           |> Multi.insert(:workspace, changeset)
           |> Oban.insert(:backfill, &BackfillIntercomWorkspace.new(%{"workspace_id" => &1.workspace.id}))
           |> Repo.transaction() do
      Phoenix.PubSub.broadcast(Rail.PubSub, "intercom_workspaces", {:intercom_workspace_changed, workspace.id})
      {:ok, workspace}
    else
      {:error, :workspace, %Ecto.Changeset{} = changeset, _changes} -> {:error, changeset}
      {:error, %Ecto.Changeset{}} = invalid -> invalid
    end
  end
end
