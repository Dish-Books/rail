defmodule Rail.Pipeline.Utils.ReviewRunFinished do
  @moduledoc """
  Where a finished Review lead turn leaves its task.

  The findings are already rows, saved one at a time, and the task stays at Review whatever they say: the
  lead recommends and a person rules, and the fixes they rule happen inside Review. A round that leaves
  nothing to rule and nothing to fix is the exception, and finishes the review by itself, taking the pull
  request out of draft. A message the human queued for the lead holds it: they have more to say.

  What a turn can get wrong is ending without `save_review` when a round was due, which is any time the
  branch has moved since the last pass read it. That is recorded on the run, so the stage stays open for
  the message that fixes it.
  """

  import Rail.Pipeline.Utils.FinishReview

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc "Finishes `run` as the Review lead's."
  def review_run_finished(%Run{} = run, _opts) do
    task = Repo.preload(run.task, :issue)
    passes = Pipeline.read_review(task)

    cond do
      not saved?(passes, task) -> fail(run, "The Review lead did not save its review.")
      run.pending_chat != nil or List.last(passes).finished_at != nil -> run
      Enum.any?(Pipeline.list_findings(task), &(Finding.undecided?(&1) or Finding.outstanding?(&1))) -> run
      true -> %{run | task: finish_review(task)}
    end
  end

  # A pass with no commit, or a worktree git cannot read, is taken at its word.
  defp saved?([], %Task{}), do: false

  defp saved?(passes, %Task{} = task) do
    read = List.last(passes).head
    now = if Task.worktree_present?(task), do: Git.branch_fingerprint(task.worktree_path)[:head_sha]
    is_nil(read) or is_nil(now) or read == now
  end

  defp fail(%Run{} = run, error) do
    {:ok, failed} = run |> Run.changeset(%{error: error}) |> Repo.update()
    %{failed | task: run.task, role: run.role}
  end
end
