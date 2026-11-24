defmodule Rail.Initiatives.Actions.UpdateInitiative do
  @moduledoc "A person's change to an initiative's name, notes or expected date."

  import Ecto.Query

  alias Rail.Initiatives.Schemas.Initiative
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Writes `attrs` over the initiative as it now reads and broadcasts `{:initiatives_changed, project_id}` on
  `"initiatives"`. Returns it as written; one deleted meanwhile is `{:error, :not_found}`.
  """
  def update_initiative(%Scope{} = scope, %Initiative{id: id, project_id: project_id}, attrs) do
    with true <- Scope.can_access_project?(scope, project_id) || {:error, :not_found},
         %Initiative{} = current <-
           Repo.one(from(i in Initiative, where: i.id == ^id and i.project_id == ^project_id)) || {:error, :not_found},
         {:ok, updated} <- current |> Initiative.changeset(attrs) |> Repo.update() do
      Phoenix.PubSub.broadcast(Rail.PubSub, "initiatives", {:initiatives_changed, project_id})
      {:ok, updated}
    end
  end
end
