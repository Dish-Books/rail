defmodule Rail.Pipeline.Actions.DecideFinding do
  @moduledoc """
  Records the human's call on one finding, with a note in the round it was made.

  The lead recommends; this is the only thing that writes what is actually going to happen. It is refused
  once the task has left Review, while the run works, because that is the run whose findings are being
  ruled on, once the review is finished, and once the finding is filed as a new issue. Nothing is learned here:
  a ruling can change until then.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.BroadcastPipelineChanged

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Sets `decision` on `finding` as the scope's user, and returns it as it now stands. The same call made
  twice notes it once. A finding filed as a new issue is refused, under its row lock, so a ruling that
  arrives while a Send files it waits for the filing and is refused then.
  """
  def decide_finding(%Scope{} = scope, %Finding{} = finding, decision) when decision in [:fix, :skip, :new_issue] do
    task = Task |> Repo.get!(finding.task_id) |> Repo.preload([:issue, :runs])

    transaction =
      Repo.transaction(fn ->
        finding = Repo.one!(from f in Finding, where: f.id == ^finding.id, lock: "FOR UPDATE")

        with :ok <- decidable(task),
             :ok <- unfiled(finding),
             {:ok, decided} <- decide(task, finding, decision, scope.user && scope.user.id) do
          decided
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    # Said only once the ruling is committed, so a page reloading on it reads the ruling.
    case transaction do
      {:ok, {:changed, decided}} ->
        Pipeline.broadcast_output_saved(task)
        # The tab badges and the board count what is left to rule, and they reload on this.
        broadcast_pipeline_changed(task)
        {:ok, decided}

      {:ok, {:unchanged, finding}} ->
        {:ok, finding}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decide(%Task{}, %Finding{decision: decision} = finding, decision, _by_id), do: {:ok, {:unchanged, finding}}

  defp decide(%Task{} = task, %Finding{} = finding, decision, by_id) do
    round = max(length(Pipeline.read_review(task)), 1)
    note = %{round: round, kind: :ruling, at: DateTime.utc_now(), decision: decision, by_id: by_id}

    with {:ok, decided} <-
           finding
           |> Finding.decision_changeset(decision, by_id)
           |> Finding.note_changeset(%{note: note})
           |> Repo.update() do
      {:ok, {:changed, decided}}
    end
  end

  defp unfiled(%Finding{issue_id: issue_id}) when is_binary(issue_id), do: {:error, :issue_filed}
  defp unfiled(%Finding{}), do: :ok

  defp decidable(%Task{stage: stage}) when stage != :review, do: {:error, {:invalid_stage, stage}}

  defp decidable(%Task{} = task) do
    cond do
      Task.running?(task) -> {:error, :stage_running}
      match?(%{finished_at: %DateTime{}}, List.last(Pipeline.read_review(task))) -> {:error, :review_finished}
      true -> :ok
    end
  end
end
