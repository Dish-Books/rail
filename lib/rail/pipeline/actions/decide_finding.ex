defmodule Rail.Pipeline.Actions.DecideFinding do
  @moduledoc """
  Records the human's call on one finding, with a note in the round it was made.

  The lead recommends; this is the only thing that writes what is actually going to happen. It is refused
  once the task has left Review, while the run works, because that is the run whose findings are being
  ruled on, once the review is finished, once the finding is filed as a new issue or fixed, and for any
  call but Fix on a finding a rule suppressed. Nothing is learned here: a ruling can change until then.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.BroadcastPipelineChanged

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Sets `decision` on `finding` as the scope's user under its row lock, and returns it as it now stands. With
  `read: %{round:, updated_at:}`, refuses a ruling read in an earlier round, or on a finding changed since.
  """
  def decide_finding(%Scope{} = scope, %Finding{} = finding, decision, opts)
      when decision in [:fix, :skip, :new_issue] and is_list(opts) do
    task = Task |> Repo.get!(finding.task_id) |> Repo.preload([:issue, runs: :role])

    transaction =
      Repo.transaction(fn ->
        finding = Repo.one!(from f in Finding, where: f.id == ^finding.id, lock: "FOR UPDATE")
        # Read after the lock, so a round saved before this ruling is the one it is checked against.
        passes = length(Pipeline.read_review(task))

        with :ok <- decidable(task),
             :ok <- unfiled(finding),
             :ok <- open(finding),
             :ok <- offered(finding, decision),
             :ok <- same_round(passes, opts[:read]),
             {:ok, decided} <- decide(finding, decision, scope.user && scope.user.id, passes, opts[:read]) do
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

  defp decide(%Finding{decision: decision} = finding, decision, _by_id, _passes, _read), do: {:ok, {:unchanged, finding}}

  defp decide(%Finding{} = finding, decision, by_id, passes, read) do
    note = %{round: max(passes, 1), kind: :ruling, at: DateTime.utc_now(), decision: decision, by_id: by_id}

    with :ok <- unchanged_since(finding, read),
         {:ok, decided} <-
           finding
           |> Finding.decision_changeset(decision, by_id)
           |> Finding.note_changeset(%{note: note})
           |> Repo.update() do
      {:ok, {:changed, decided}}
    end
  end

  defp same_round(_passes, nil), do: :ok
  defp same_round(passes, %{round: passes}), do: :ok
  defp same_round(_passes, %{round: _earlier}), do: {:error, :round_changed}

  defp unchanged_since(%Finding{}, nil), do: :ok

  defp unchanged_since(%Finding{updated_at: updated_at}, %{updated_at: %DateTime{} = read_at}) do
    if DateTime.compare(updated_at, read_at) == :eq, do: :ok, else: {:error, :finding_changed}
  end

  defp open(%Finding{status: :fixed}), do: {:error, :finding_fixed}
  defp open(%Finding{}), do: :ok

  # Its rule already leaves a suppressed finding alone, so Fix is the only call the page offers on it.
  defp offered(%Finding{} = finding, decision) do
    if Finding.suppressed?(finding) and decision != :fix, do: {:error, :suppressed}, else: :ok
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
