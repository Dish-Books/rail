defmodule Rail.Learnings.Actions.ListLearningProposals do
  @moduledoc false

  import Ecto.Query
  import Pgvector.Ecto.Query

  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Repo

  @kinds Learning.kinds()

  @doc """
  The pending proposals, oldest first, each with its draft or subject rule and who decided it.
  Filters by `:project_id`, one id or a list, by `:task_id`, `:none` for those of no task, by `:support_conversation_id`,
  `:none` for those Support did not propose, and by `:kind`, the rule's; `:statuses` widens it past pending.
  An `:embedding` ranks the 50 whose rule is nearest it first, leaving out a rule not embedded yet. `targets: true` loads the
  rules each one replaces.
  """
  def list_learning_proposals(opts \\ []) do
    from(p in LearningProposal,
      as: :proposal,
      join: l in assoc(p, :learning),
      as: :learning,
      where: p.status in ^Keyword.get(opts, :statuses, [:pending]),
      preload: [:project, :decided_by, learning: l]
    )
    |> filter_project(opts[:project_id])
    |> filter_task(opts[:task_id])
    |> filter_support(opts[:support_conversation_id])
    |> filter_kind(opts[:kind])
    |> rank(opts[:embedding])
    |> Repo.all()
    |> load_targets(opts[:targets])
  end

  defp filter_project(query, project_id) when is_binary(project_id),
    do: where(query, [proposal: p], p.project_id == ^project_id)

  defp filter_project(query, ids) when is_list(ids), do: where(query, [proposal: p], p.project_id in ^ids)
  defp filter_project(query, nil), do: query

  defp filter_task(query, task_id) when is_binary(task_id), do: where(query, [proposal: p], p.task_id == ^task_id)
  defp filter_task(query, :none), do: where(query, [proposal: p], is_nil(p.task_id))
  defp filter_task(query, nil), do: query

  defp filter_support(query, :none), do: where(query, [proposal: p], is_nil(p.support_conversation_id))
  defp filter_support(query, nil), do: query

  defp filter_kind(query, kind) when kind in @kinds, do: where(query, [learning: l], l.kind == ^kind)
  defp filter_kind(query, nil), do: query

  defp rank(query, nil), do: order_by(query, [proposal: p], asc: p.inserted_at, asc: p.id)

  defp rank(query, embedding) when is_list(embedding) do
    vector = Pgvector.new(embedding)

    query
    |> where([learning: l], not is_nil(l.embedding))
    |> order_by([learning: l, proposal: p], asc: cosine_distance(l.embedding, ^vector), asc: p.id)
    |> limit(50)
  end

  # One query for the whole list, in the first proposal's project, which is every one's when the list is one task's.
  defp load_targets([%LearningProposal{project_id: project_id} | _rest] = proposals, true) do
    ids = proposals |> Enum.flat_map(& &1.target_ids) |> Enum.uniq()
    rules = Map.new(Repo.all(from l in Learning, where: l.id in ^ids and l.project_id == ^project_id), &{&1.id, &1})
    Enum.map(proposals, &%{&1 | targets: for(id <- &1.target_ids, Map.has_key?(rules, id), do: rules[id])})
  end

  defp load_targets(proposals, _none_or_not_asked), do: proposals
end
