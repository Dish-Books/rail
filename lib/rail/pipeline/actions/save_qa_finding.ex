defmodule Rail.Pipeline.Actions.SaveQaFinding do
  @moduledoc """
  Upserts one finding QA saved, by its key, keeping the human's decision; evidence
  is checked here, so nothing reaches the panel that it cannot show.
  """

  import Ecto.Changeset

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.QaEvidence
  alias Rail.Pipeline.Schemas.QaFinding
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  # Every column QA writes, and nothing else: `decision` is the human's and
  # `inserted_at` is when the defect was first raised.
  @restated [
    :title,
    :check,
    :criterion,
    :screen,
    :steps,
    :expected,
    :observed,
    :detail,
    :suggestion,
    :severity,
    :recommendation,
    :status,
    :caused_by_change,
    :evidence,
    :updated_at
  ]

  @doc """
  Saves the finding in `attrs` on `task`. Returns `{:ok, finding}` as the row
  now stands, or `{:error, changeset}`.
  """
  def save_qa_finding(%Task{} = task, attrs) when is_map(attrs) do
    qa_dir = Path.join(task.scratch_path, "qa")

    changeset =
      %QaFinding{task_id: task.id}
      |> QaFinding.changeset(Map.drop(attrs, [:task_id, "task_id"]))
      |> validate_filed(qa_dir)

    with {:ok, finding} <-
           Repo.insert(changeset, on_conflict: {:replace, @restated}, conflict_target: [:task_id, :key], returning: true) do
      Pipeline.broadcast_output_saved(task)
      {:ok, finding}
    end
  end

  # The schema already holds a path to the QA folder; this holds it to a file
  # that is there, which only the folder itself can answer.
  defp validate_filed(changeset, qa_dir) do
    missing =
      for %QaEvidence{path: path} when is_binary(path) <- get_field(changeset, :evidence),
          QaEvidence.confined?(path),
          not File.regular?(Path.join(qa_dir, path)),
          do: path

    case missing do
      [] -> changeset
      paths -> add_error(changeset, :evidence, "#{Enum.join(paths, ", ")} is not a file in #{qa_dir}")
    end
  end
end
