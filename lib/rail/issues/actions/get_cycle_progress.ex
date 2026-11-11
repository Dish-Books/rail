defmodule Rail.Issues.Actions.GetCycleProgress do
  @moduledoc false

  import Ecto.Query
  import Rail.Issues.Utils.SumCyclePoints

  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Users.Schemas.User

  @doc """
  A cycle's scope, started (done work included) and completed points, without canceled or duplicate issues and with an
  unestimated one at the team's default, the scope's change since day one, and each owner's points, most first. An
  ended Rail cycle counts its issues in the state they closed in.
  """
  def get_cycle_progress(%Project{id: project_id}, %{id: cycle_id, default_estimate: estimate} = cycle) do
    rows = sum_cycle_points(project_id, cycle_id, estimate)

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
