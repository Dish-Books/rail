defmodule Rail.Issues.Actions.GetCycleProgress do
  @moduledoc false

  import Ecto.Query

  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Users.Schemas.User

  @doc """
  A cycle's figures from the project's issues in it, canceled and duplicate ones left out and an unestimated one
  counted at the team's default: scope, started and completed points, the scope's change in percent since the
  cycle's first day, or nil before it has one, and each owner's points and completed points, most points first.
  """
  def get_cycle_progress(%Project{id: project_id}, %{id: cycle_id, default_estimate: estimate} = cycle) do
    rows =
      Repo.all(
        from(i in Issue,
          where: i.project_id == ^project_id and i.cycle_external_id == ^cycle_id,
          where: i.state not in ^[:canceled, :duplicate],
          group_by: i.owner_user_id,
          select: {
            i.owner_user_id,
            sum(coalesce(i.estimate, ^estimate)),
            coalesce(filter(sum(coalesce(i.estimate, ^estimate)), i.state in ^[:in_progress, :in_review]), 0),
            coalesce(filter(sum(coalesce(i.estimate, ^estimate)), i.state == ^:done), 0)
          }
        )
      )

    scope = rows |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    owner_ids = for {id, _points, _started, _completed} <- rows, is_binary(id), do: id
    users = from(u in User, where: u.id in ^owner_ids) |> Repo.all() |> Map.new(&{&1.id, &1})

    for_result =
      for(
        {id, points, _started, completed} <- rows,
        %User{} = user <- [users[id]],
        do: %{user: user, points: points, completed: completed}
      )

    owners = Enum.sort_by(for_result, &{-&1.points, &1.user.name || &1.user.login, &1.user.id})

    %{
      scope: scope,
      started: rows |> Enum.map(&elem(&1, 2)) |> Enum.sum(),
      completed: rows |> Enum.map(&elem(&1, 3)) |> Enum.sum(),
      scope_change: scope_change(scope, cycle.scope_history),
      owners: owners
    }
  end

  defp scope_change(scope, [first | _later]) when first > 0, do: round((scope - first) / first * 100)
  defp scope_change(_scope, _no_history), do: nil
end
