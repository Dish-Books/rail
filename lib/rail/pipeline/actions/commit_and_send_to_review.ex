defmodule Rail.Pipeline.Actions.CommitAndSendToReview do
  @moduledoc """
  A human's commit is also their word that the work is ready for review, so once
  it is pushed, through CI where the project has it, the task goes on to review.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Commits the engineer's work on `run` and sends it to review once it is pushed.

  Returns `{:ok, run}`, running while CI decides, or `{:error, reason}` when the
  commit, the push or review refused.
  """
  def commit_and_send_to_review(%Scope{} = scope, %Run{} = run) do
    run = Repo.preload(run, :task)

    # Set before committing, so a CI that finishes fast still finds it.
    {:ok, flagged} = run |> Run.changeset(%{review_on_ci_pass: true}) |> Repo.update()

    case Pipeline.commit_engineer_work(scope, run.task, nil) do
      :ok ->
        send_on(Repo.get!(Run, flagged.id))

      {:error, reason} ->
        {:ok, _cleared} = flagged |> Run.changeset(%{review_on_ci_pass: false}) |> Repo.update()
        {:error, reason}
    end
  end

  # Starting CI moved the run on, and CI's finish sends it; with no CI, or CI
  # already passed, the push was the whole of it, and settles any push that failed.
  defp send_on(%Run{status: :running} = running), do: {:ok, running}

  defp send_on(%Run{} = pushed) do
    {:ok, cleared} = pushed |> Run.changeset(%{review_on_ci_pass: false, error: nil}) |> Repo.update()
    Pipeline.send_to_review(cleared)
  end
end
