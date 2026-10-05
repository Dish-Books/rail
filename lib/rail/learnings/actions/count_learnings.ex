defmodule Rail.Learnings.Actions.CountLearnings do
  @moduledoc false

  import Ecto.Query

  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Repo

  @doc """
  The page's four segments: pending proposals, then active, provisional and
  retired rules, for `:project_id` (one id or a list) or every project.
  """
  def count_learnings(opts \\ []) do
    project_id = opts[:project_id]

    rules =
      from(l in Learning,
        where: l.status in [:active, :provisional, :retired],
        group_by: l.status,
        select: {l.status, count(l.id)}
      )
      |> in_project(project_id)
      |> Repo.all()
      |> Map.new()

    review =
      from(p in LearningProposal, where: p.status == :pending)
      |> in_project(project_id)
      |> Repo.aggregate(:count)

    %{
      review: review,
      active: Map.get(rules, :active, 0),
      provisional: Map.get(rules, :provisional, 0),
      retired: Map.get(rules, :retired, 0)
    }
  end

  defp in_project(query, project_id) when is_binary(project_id), do: where(query, [row], row.project_id == ^project_id)
  defp in_project(query, ids) when is_list(ids), do: where(query, [row], row.project_id in ^ids)
  defp in_project(query, nil), do: query
end
