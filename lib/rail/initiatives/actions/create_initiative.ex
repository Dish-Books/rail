defmodule Rail.Initiatives.Actions.CreateInitiative do
  @moduledoc "A person's new initiative in one of their projects."

  alias Rail.Initiatives.Schemas.Initiative
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  @doc "Creates the initiative in `project` and broadcasts `{:initiatives_changed, project_id}` on `\"initiatives\"`."
  def create_initiative(%Scope{} = scope, %Project{id: project_id}, attrs) do
    if Scope.can_access_project?(scope, project_id) do
      with {:ok, initiative} <- %Initiative{project_id: project_id} |> Initiative.changeset(attrs) |> Repo.insert() do
        Phoenix.PubSub.broadcast(Rail.PubSub, "initiatives", {:initiatives_changed, project_id})
        {:ok, initiative}
      end
    else
      {:error, :not_found}
    end
  end
end
