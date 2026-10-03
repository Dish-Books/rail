defmodule Rail.Learnings.Actions.ListLearningProposals do
  @moduledoc false

  import Ecto.Query

  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Repo

  @kinds Learning.kinds()

  @doc """
  The pending proposals, oldest first, each with its draft or subject rule.
  Filters by `:project_id`, one id or a list, and by `:kind`, the rule's.
  """
  def list_learning_proposals(opts \\ []) do
    from(p in LearningProposal,
      as: :proposal,
      join: l in assoc(p, :learning),
      as: :learning,
      where: p.status == :pending,
      order_by: [asc: p.inserted_at, asc: p.id],
      preload: [:project, learning: l]
    )
    |> filter_project(opts[:project_id])
    |> filter_kind(opts[:kind])
    |> Repo.all()
  end

  defp filter_project(query, project_id) when is_binary(project_id),
    do: where(query, [proposal: p], p.project_id == ^project_id)

  defp filter_project(query, ids) when is_list(ids), do: where(query, [proposal: p], p.project_id in ^ids)
  defp filter_project(query, nil), do: query

  defp filter_kind(query, kind) when kind in @kinds, do: where(query, [learning: l], l.kind == ^kind)
  defp filter_kind(query, nil), do: query
end
