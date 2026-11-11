defmodule Rail.Issues.Actions.SetIssueCycle do
  @moduledoc """
  A person's move of a Rail-tracked issue into a cycle that has not ended, or out of its cycle.
  """

  import Ecto.Query

  alias Rail.Issues.Schemas.Cycle
  alias Rail.Issues.Schemas.Issue
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Puts `issue` in the cycle `cycle_id` names, or in none for nil, and broadcasts `{:issue_changed, issue_id}` on
  `"issues"`. Returns the issue as it now reads, unwritten when it already has that cycle.
  """
  def set_issue_cycle(%Scope{} = scope, %Issue{id: id, project_id: project_id}, cycle_id) do
    # Read again, both under the issue's own project: a queued pick can name a cycle the page no longer offers.
    current = Repo.one(from(i in Issue, where: i.id == ^id and i.project_id == ^project_id))
    cycle = cycle_id && Repo.one(from(c in Cycle, where: c.id == ^cycle_id and c.project_id == ^project_id))

    cond do
      is_nil(current) or current.tracker != :local or not Scope.can_access_project?(scope, project_id) ->
        {:error, :not_found}

      is_binary(cycle_id) and (is_nil(cycle) or Cycle.calculate_status(cycle, Date.utc_today()) == :ended) ->
        {:error, :not_found}

      current.cycle_external_id == cycle_id ->
        {:ok, current}

      true ->
        with {:ok, issue} <- current |> Issue.tracker_changeset(%{cycle_external_id: cycle_id}) |> Repo.update() do
          Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_changed, id})
          {:ok, issue}
        end
    end
  end
end
