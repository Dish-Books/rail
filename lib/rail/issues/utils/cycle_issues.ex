defmodule Rail.Issues.Utils.CycleIssues do
  @moduledoc """
  A cycle's issues as its filters, counts and points judge them: those in it now, and those it held when it closed, in
  the state they closed in. `list_issues/1` returns the live rows beside this reading.
  """

  import Ecto.Query

  alias Rail.Issues.Schemas.ClosedCycleIssue
  alias Rail.Issues.Schemas.Issue

  @doc """
  A query over the issues of the cycles `cycle_ids` names in the projects `project_ids` names. One a cycle held when it
  closed reads with that state and no status name, so every filter, count and point judges it as it closed.
  """
  def cycle_issues(project_ids, cycle_ids) when is_list(project_ids) and is_list(cycle_ids) do
    # Joined only on the cycles named, so an issue that closed in other cycles too comes back once.
    subquery(
      from(i in Issue,
        left_join: c in ClosedCycleIssue,
        on: c.issue_id == i.id and c.cycle_id in ^cycle_ids,
        where: i.project_id in ^project_ids,
        where: i.cycle_external_id in ^cycle_ids or not is_nil(c.id),
        select: %{
          i
          | state: coalesce(c.state, i.state),
            state_name: fragment("CASE WHEN ? IS NULL THEN ? END", c.id, i.state_name)
        }
      )
    )
  end
end
