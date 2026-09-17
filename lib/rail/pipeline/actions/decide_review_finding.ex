defmodule Rail.Pipeline.Actions.DecideReviewFinding do
  @moduledoc """
  Records the human's call on one finding.

  The reviewer recommends; this is the only thing that writes what is actually
  going to happen. It is refused once the task has left review, because the
  decision's whole effect is on what the next send-back carries, and refused
  while something is running, because that is the run whose findings are being
  ruled on.
  """

  alias Rail.Pipeline.Schemas.ReviewFinding
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Sets `decision` on `finding`, and returns it as it now stands.
  """
  def decide_review_finding(%ReviewFinding{} = finding, decision) when decision in [:fix, :skip] do
    task = Repo.preload(Repo.get!(Task, finding.task_id), :runs)

    with :ok <- decidable(task) do
      finding |> ReviewFinding.decision_changeset(decision) |> Repo.update()
    end
  end

  defp decidable(%Task{stage: stage}) when stage != :review, do: {:error, {:invalid_stage, stage}}

  defp decidable(%Task{} = task) do
    if Task.running?(task), do: {:error, :stage_running}, else: :ok
  end
end
