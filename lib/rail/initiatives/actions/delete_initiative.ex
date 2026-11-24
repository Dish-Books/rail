defmodule Rail.Initiatives.Actions.DeleteInitiative do
  @moduledoc "A person's delete of an initiative, which leaves its tickets with none."

  import Ecto.Query

  alias Rail.Initiatives.Schemas.Initiative
  alias Rail.Issues.Schemas.Issue
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Deletes the initiative with its briefs; the database unlinks its tickets. Broadcasts on `"initiatives"`, and
  `{:issue_changed, id}` on `"issues"` for each ticket it held, so their pages drop its name.
  """
  def delete_initiative(%Scope{} = scope, %Initiative{id: id, project_id: project_id}) do
    with true <- Scope.can_access_project?(scope, project_id) || {:error, :not_found},
         {:ok, issue_ids} <- delete(id, project_id) do
      Phoenix.PubSub.broadcast(Rail.PubSub, "initiatives", {:initiatives_changed, project_id})
      for issue_id <- issue_ids, do: Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_changed, issue_id})
      :ok
    end
  end

  # Locked first, so a ticket joining meanwhile waits on the row and then fails, rather than going unannounced.
  defp delete(id, project_id) do
    Repo.transaction(fn ->
      query = from(i in Initiative, where: i.id == ^id and i.project_id == ^project_id)

      if is_nil(Repo.one(lock(query, "FOR UPDATE"))), do: Repo.rollback(:not_found)

      issue_ids =
        Repo.all(from(i in Issue, where: i.initiative_id == ^id and i.project_id == ^project_id, select: i.id))

      {1, _rows} = Repo.delete_all(query)
      issue_ids
    end)
  end
end
