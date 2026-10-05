defmodule Rail.Pipeline.Actions.SaveReviewFinding do
  @moduledoc """
  Upserts one finding the reviewer saved, by key, never overwriting the human's
  decision; a calibration rule's id suppresses it, another's is its `rule`.
  """

  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ReviewFinding
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  # Every column the reviewer writes, and nothing else: `decision` is the human's
  # and `inserted_at` is when the problem was first raised.
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

  # What the reviewer may not set by name: the task is the one saving, and a rule
  # is linked only by looking up the id it gave.
  @linked [:task_id, "task_id", :rule_id, "rule_id", :suppressed_by_id, "suppressed_by_id"]

  @doc """
  Saves the finding in `attrs` on `task`. Returns `{:ok, finding}` as the row
  now stands, or `{:error, changeset}`.
  """
  def save_review_finding(%Task{} = task, attrs) when is_map(attrs) do
    rule = attrs[:rule] || attrs["rule"]
    given = Map.drop(attrs, [:rule, "rule" | @linked])

    changeset =
      %ReviewFinding{task_id: task.id}
      |> ReviewFinding.changeset(given)
      |> Ecto.Changeset.change(link(task, rule))

    with {:ok, finding} <-
           Repo.insert(changeset, on_conflict: {:replace, @restated}, conflict_target: [:task_id, :key], returning: true) do
      Pipeline.broadcast_output_saved(task)
      {:ok, finding}
    end
  end

  defp link(%Task{project_id: project_id}, id) when is_binary(id) do
    case Learnings.list_learnings(ids: [id], project_id: project_id) do
      {:ok, [%Learning{kind: :calibration}]} -> %{rule_id: nil, suppressed_by_id: id}
      {:ok, [%Learning{}]} -> %{rule_id: id, suppressed_by_id: nil}
      {:ok, []} -> %{rule_id: nil, suppressed_by_id: nil}
    end
  end

  defp link(%Task{}, _no_rule), do: %{rule_id: nil, suppressed_by_id: nil}
end
