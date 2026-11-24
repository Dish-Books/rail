defmodule Rail.Issues.Actions.SetIssueInitiative do
  @moduledoc "A person's move of an issue into one of its project's initiatives, or out of its initiative."

  import Ecto.Query

  alias Rail.Initiatives.Schemas.Initiative
  alias Rail.Issues.Schemas.Issue
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Puts `issue` in the initiative `initiative_id` names, or in none for nil, leaving its parent and cycle alone.
  Broadcasts `{:issue_changed, issue_id}` on `"issues"` and `{:initiatives_changed, project_id}` on `"initiatives"`.
  Returns the issue as it now reads, unwritten when it already has that initiative.
  """
  def set_issue_initiative(%Scope{} = scope, %Issue{id: id, project_id: project_id}, initiative_id) do
    # Both read under the issue's own project, so another project's initiative is one that does not exist.
    current = Repo.one(from(i in Issue, where: i.id == ^id and i.project_id == ^project_id))

    initiative =
      initiative_id && Repo.one(from(i in Initiative, where: i.id == ^initiative_id and i.project_id == ^project_id))

    cond do
      is_nil(current) or not Scope.can_access_project?(scope, project_id) ->
        {:error, :not_found}

      is_binary(initiative_id) and is_nil(initiative) ->
        {:error, :not_found}

      current.initiative_id == initiative_id ->
        {:ok, current}

      true ->
        with {:ok, issue} <- current |> Issue.tracker_changeset(%{initiative_id: initiative_id}) |> Repo.update() do
          Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_changed, id})
          Phoenix.PubSub.broadcast(Rail.PubSub, "initiatives", {:initiatives_changed, project_id})
          {:ok, issue}
        end
    end
  end
end
