defmodule Rail.Issues.Utils.SumCyclePoints do
  @moduledoc """
  The points rule of a cycle's progress, shared by the panel's live figures and the days Rail records.
  """

  import Ecto.Query
  import Rail.Issues.Utils.CycleIssues

  alias Rail.Repo

  @doc """
  One `{owner_user_id, scope, started, completed}` per owner of the cycle's issues as it holds them, without canceled or
  duplicate ones and with an unestimated one at `default_estimate`. Started counts done work too.
  """
  def sum_cycle_points(project_id, cycle_id, default_estimate) do
    Repo.all(
      from(i in cycle_issues([project_id], [cycle_id]),
        where: i.state not in ^[:canceled, :duplicate],
        group_by: i.owner_user_id,
        select: {
          i.owner_user_id,
          sum(coalesce(i.estimate, ^default_estimate)),
          coalesce(
            filter(sum(coalesce(i.estimate, ^default_estimate)), i.state in ^[:in_progress, :in_review, :done]),
            0
          ),
          coalesce(filter(sum(coalesce(i.estimate, ^default_estimate)), i.state == ^:done), 0)
        }
      )
    )
  end
end
