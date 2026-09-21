defmodule Rail.Pipeline.Actions.SendToReview do
  @moduledoc """
  Hands the engineer's work to review, once a human has read it.

  The engineer's commits are the artifact, so there is nothing to capture here:
  the branch already carries everything. What this is for is the same one-way
  door the earlier stages have — the task leaves engineer, and a task no longer
  there has nothing left to send.

  A worktree with uncommitted work in it is refused rather than swept up, since
  a commit made without anyone naming it is a commit nobody meant, and so is a
  branch the remote has never heard of, which is not a branch anyone else can
  review. The diff pane has a button for both.
  """

  import Rail.Pipeline.Utils.SendBack

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
      send_back(run.task, :review, returning())
      {:ok, _next} = Pipeline.enter_stage(run.task, :review)

      {:ok, %{latched | task: run.task, role: run.role}}
    end
  end

  # The brief the reviewer is spawned with never reaches its log, so without this
  # the change simply comes back round with nothing in the conversation marking
  # that it did, or saying what the reviewer is being asked to look at again.
  defp returning do
    """
    The engineer has worked on your findings and pushed the change again. Read it as it now stands and say, for every finding still open, whether it has been addressed. Review the new work on its own terms as well: a fix can be wrong, or right and break something next to it, and a finding raised this round is as much your business as one raised last round.
    """
  end

  defp sendable(%Task{stage: stage}) when stage != :engineer, do: {:error, {:invalid_stage, stage}}

  defp sendable(%Task{} = task) do
    cond do
      Task.running?(task) -> {:error, :stage_running}
      Git.worktree_dirty?(task.worktree_path) -> {:error, :uncommitted_changes}
      Git.branch_unpushed?(task.worktree_path) -> {:error, :unpushed_changes}
      true -> :ok
    end
  end
end
