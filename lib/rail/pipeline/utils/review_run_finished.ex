defmodule Rail.Pipeline.Utils.ReviewRunFinished do
  @moduledoc """
  Where a finished review agent turn leaves its task.

  The findings are already rows, saved one at a time, and the task stays at Review whatever they say: the agent
  recommends, a person rules, and an engineer makes the fixes in the next round. What a turn can get wrong is
  recorded on the run, so it stays open for the message that settles it: ending without `save_review` when the
  branch has moved since the last review, leaving something to fix with no plan for it, leaving a plan the
  round's changes outdated unrevised, or committing, which is the engineer's alone.

  A review that leaves nothing to rule, nothing to fix and no plan finishes by itself, taking the pull request out
  of draft. A message the human queued holds it, as anyone's unsent finding, diff or screen comment does: they
  have more to say.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.FinishReview

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingComment
  alias Rail.Pipeline.Schemas.FixPlan
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.ScreenComment
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc "Finishes `run` as the review agent's."
  def review_run_finished(%Run{} = run, _opts) do
    task = Repo.preload(run.task, :issue)
    passes = Pipeline.read_review(task)
    findings = Pipeline.list_findings(task)
    # A plan approved for an earlier round is that round's, and says nothing of this one.
    plan = with %FixPlan{approved_at: %DateTime{}} <- Pipeline.read_fix_plan(task), do: nil

    cond do
      Task.worktree_present?(task) and Git.branch_unpushed?(task.worktree_path) ->
        fail(run, "The review agent committed. Only the engineer changes the branch, so nothing was sent on.")

      not saved?(passes, task) ->
        fail(run, "The review agent did not save its review.")

      plan != nil and FixPlan.state(plan, task, findings) in [:writing, :revising] ->
        fail(run, "The review agent did not save the round's plan.")

      plan == nil and task.stage == :review and Enum.any?(findings, &Finding.outstanding?/1) ->
        fail(run, "The review agent left findings to fix with no plan for the next round.")

      plan != nil or run.pending_chat != nil or List.last(passes).finished_at != nil ->
        run

      Enum.any?(findings, &Finding.undecided?/1) or unsent_comments?(task) ->
        run

      true ->
        %{run | task: finish_review(task)}
    end
  end

  defp unsent_comments?(%Task{id: task_id}) do
    Repo.exists?(from c in FindingComment, where: c.task_id == ^task_id and c.status == :unsent) or
      Repo.exists?(from c in DiffComment, where: c.task_id == ^task_id and c.status == :unsent) or
      Repo.exists?(from c in ScreenComment, where: c.task_id == ^task_id and c.status == :unsent)
  end

  # A pass with no commit, or a worktree git cannot read, is taken at its word.
  defp saved?([], %Task{}), do: false

  # Past Review nobody rules a round, so a turn at Finalize or after the merge owes none.
  defp saved?(_passes, %Task{stage: stage}) when stage in [:finalize, :merged], do: true

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
