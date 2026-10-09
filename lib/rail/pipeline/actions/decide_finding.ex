defmodule Rail.Pipeline.Actions.DecideFinding do
  @moduledoc """
  Records the human's call on one finding, with a note in the round it was made.

  The lead recommends; this is the only thing that writes what is actually going to happen. It is refused
  once the task has left Review, while the run works, because that is the run whose findings are being
  ruled on, and once the review is finished. Nothing is learned here: a ruling can change until then.
  """

  import Rail.Pipeline.Utils.BroadcastPipelineChanged

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Sets `decision` on `finding` as the scope's user, and returns it as it now stands. The same call made
  twice notes it once.
  """
  def decide_finding(%Scope{} = scope, %Finding{} = finding, decision) when decision in [:fix, :skip] do
    task = Task |> Repo.get!(finding.task_id) |> Repo.preload([:issue, :runs])
    finding = Repo.get!(Finding, finding.id)

    with :ok <- decidable(task) do
      decide(task, finding, decision, scope.user && scope.user.id)
    end
  end

  defp decide(%Task{}, %Finding{decision: decision} = finding, decision, _by_id), do: {:ok, finding}

  defp decide(%Task{} = task, %Finding{} = finding, decision, by_id) do
    round = max(length(Pipeline.read_review(task)), 1)
    note = %{round: round, kind: :ruling, at: DateTime.utc_now(), decision: decision, by_id: by_id}

    with {:ok, decided} <-
           finding
           |> Finding.decision_changeset(decision, by_id)
           |> Finding.note_changeset(%{note: note})
           |> Repo.update() do
      Pipeline.broadcast_output_saved(task)
      # The tab badges and the board count what is left to rule, and they reload on this.
      broadcast_pipeline_changed(task)
      {:ok, decided}
    end
  end

  defp decidable(%Task{stage: stage}) when stage != :review, do: {:error, {:invalid_stage, stage}}

  defp decidable(%Task{} = task) do
    cond do
      Task.running?(task) -> {:error, :stage_running}
      match?(%{finished_at: %DateTime{}}, List.last(Pipeline.read_review(task))) -> {:error, :review_finished}
      true -> :ok
    end
  end
end
