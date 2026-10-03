defmodule Rail.Pipeline.Actions.SyncReviewFindings do
  @moduledoc """
  Folds the findings a review pass wrote into the rows the task already carries.

  A finding is matched by the key the reviewer gave it, so a second pass updates
  what it said about the same problem rather than raising it again. What it may
  not touch is `decision`: that is the human's call, and a review that overwrote
  it would re-open everything they dismissed every time it ran.

  A key the reviewer dropped is left alone rather than deleted. It was raised
  once and ruled on once, and a pass that stopped listing it has said nothing
  about it.

  A calibration rule's id suppresses the finding naming it and any other rule's is
  its `rule`; an id this project has no rule by is the agent's mistake and dropped.
  """

  import Ecto.Query

  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Pipeline.Schemas.ReviewFinding
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  # What a later pass is allowed to restate. `decision` is the human's and
  # `inserted_at` is when the problem was first raised, so neither is replaced,
  # and `id` stays whatever the row was given when it was inserted. A column the
  # reviewer writes and this list forgets is a column that never reaches an
  # existing row, so every field in the changeset belongs here or is deliberately
  # left out.
  @restated [
    :title,
    :detail,
    :suggestion,
    :file,
    :line,
    :severity,
    :recommendation,
    :status,
    :rule_id,
    :suppressed_by_id,
    :updated_at
  ]

  @doc """
  Records `findings` against `task`, and returns them all as they now stand,
  oldest first.
  """
  def sync_review_findings(%Task{} = task, findings) when is_list(findings) do
    rules = rules(task, findings)

    {:ok, synced} =
      Repo.transaction(fn ->
        Enum.each(findings, &upsert(task, link(&1, rules)))
        rows(task)
      end)

    {:ok, synced}
  end

  defp rows(%Task{id: task_id}) do
    Repo.all(from f in ReviewFinding, where: f.task_id == ^task_id, order_by: [asc: f.inserted_at, asc: f.id])
  end

  defp rules(%Task{project_id: project_id}, findings) do
    case for(%{rule: id} <- findings, is_binary(id), do: id) do
      [] ->
        %{}

      ids ->
        {:ok, rules} = Learnings.list_learnings(ids: Enum.uniq(ids), project_id: project_id)
        Map.new(rules, &{&1.id, &1})
    end
  end

  defp link(finding, rules) do
    {id, finding} = Map.pop(finding, :rule)

    case Map.get(rules, id) do
      %Learning{kind: :calibration} -> Map.merge(finding, %{rule_id: nil, suppressed_by_id: id})
      %Learning{} -> Map.merge(finding, %{rule_id: id, suppressed_by_id: nil})
      nil -> Map.merge(finding, %{rule_id: nil, suppressed_by_id: nil})
    end
  end

  defp upsert(%Task{} = task, finding) do
    %ReviewFinding{}
    |> ReviewFinding.changeset(Map.put(finding, :task_id, task.id))
    |> Repo.insert!(on_conflict: {:replace, @restated}, conflict_target: [:task_id, :key])
  end
end
