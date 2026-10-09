defmodule Rail.Pipeline.Actions.SendToReview do
  @moduledoc """
  Hands the engineer's work to Review, by a person's click or once CI passes on the engineer's commit.

  The engineer's commits are the artifact, so there is nothing to capture here:
  the branch already carries everything. What this is for is the same one-way
  door the earlier stages have: the task leaves Engineer, and the fixes Review
  asks for are made inside Review.

  A worktree with uncommitted work in it is refused rather than swept up, since
  a commit made without anyone naming it is a commit nobody meant, and so is a
  branch the remote has never heard of, which is not a branch anyone else can
  review. The diff pane has a button for both.
  """

  import Rail.Pipeline.Utils.CiPassed

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  @doc """
  Sends `run`'s task to the review stage.

  Returns `{:ok, run}`, the run that was handed in, latched done.
  """
  def send_to_review(%Run{} = run) do
    run = Repo.preload(run, [task: [:issue, :project, :runs]], force: true)

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
      Git.branch_unpushed?(task.worktree_path) -> {:error, :unpushed_changes}
      ci_required?(task) and not ci_passed?(task) -> {:error, :ci_not_passed}
      true -> :ok
    end
  end

  defp ci_required?(%Task{project: %Project{ci_command: command}}), do: command not in [nil, ""]
end
