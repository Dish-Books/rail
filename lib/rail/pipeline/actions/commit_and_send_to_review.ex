defmodule Rail.Pipeline.Actions.CommitAndSendToReview do
  @moduledoc """
  A commit at Engineer, the human's or the engineer's own `commit`, is also the word that the work is
  ready for review, so once it is pushed, through CI where the project has it, the task goes on to Review.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Commits the engineer's work on `run` under `message`, the engineer's words or none for the human's
  button, and sends it to review once it is pushed.

  Returns `{:ok, run}`, running while CI decides, or `{:error, reason}` when the
  task has left Engineer or the commit, the push or review refused.
  """
  def commit_and_send_to_review(%Scope{} = scope, %Run{} = run, message \\ nil) do
    run = Repo.preload(run, :task, force: true)

    with :ok <- committable(run.task) do
      # Set before committing, so a CI that finishes fast still finds it.
      {:ok, flagged} = run |> Run.changeset(%{review_on_ci_pass: true}) |> Repo.update()

      case Pipeline.commit_engineer_work(scope, run.task, message) do
        :ok ->
          send_on(Repo.get!(Run, flagged.id))

        {:error, reason} ->
          {:ok, _cleared} = flagged |> Run.changeset(%{review_on_ci_pass: false}) |> Repo.update()
          {:error, reason}
      end
    end
  end

  defp committable(%Task{stage: :engineer}), do: :ok
  defp committable(%Task{stage: stage}), do: {:error, {:invalid_stage, stage}}

  # Starting CI moved the run on, and CI's finish sends it; with no CI, or CI
  # already passed, the push was the whole of it, and settles any push that failed.
  defp send_on(%Run{status: :running} = running), do: {:ok, running}

  defp send_on(%Run{} = pushed) do
    {:ok, cleared} = pushed |> Run.changeset(%{review_on_ci_pass: false, error: nil}) |> Repo.update()
    Pipeline.send_to_review(cleared)
  end
end
