defmodule Rail.Pipeline.Actions.SendToReview do
  @moduledoc """
  Hands the engineer's work to review, once a human has read it.

  The engineer's commits are the artifact, so there is nothing to capture here:
  the branch already carries everything. What this is for is the same one-way
  door the earlier stages have — the task leaves engineer, and a task no longer
  there has nothing left to send.

  A worktree with uncommitted work in it is refused rather than swept up, since
  a commit made without anyone naming it is a commit nobody meant. The diff pane
  has a Commit button for exactly that.
  """

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Sends `run`'s task to the review stage.

  Returns `{:ok, run}`, the run that was handed in, latched done.
  """
  def send_to_review(%Run{} = run) do
    run = Repo.preload(run, [task: [:issue, :runs]], force: true)

    with :ok <- sendable(run.task) do
      {:ok, latched} = run |> Run.changeset(%{stage_outcome: :done}) |> Repo.update()
      {:ok, _next} = Pipeline.enter_stage(run.task, :review)

      {:ok, %{latched | task: run.task, role: run.role}}
    end
  end

  defp sendable(%Task{stage: stage}) when stage != :engineer, do: {:error, {:invalid_stage, stage}}

  defp sendable(%Task{} = task) do
    cond do
      Task.running?(task) -> {:error, :stage_running}
      Git.worktree_dirty?(task.worktree_path) -> {:error, :uncommitted_changes}
      true -> :ok
    end
  end
end
