defmodule Rail.Pipeline.Actions.DiscardTask do
  @moduledoc """
  The task page's Discard: stops every run, closes the pull request, deletes the branch on GitHub, then deletes the
  task with its files, runs, questions, findings and comments and puts the ticket back to not started.
  """

  import Rail.Pipeline.Utils.BroadcastPipelineChanged
  import Rail.Pipeline.Utils.ClearBranch

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Learnings
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Discards `task` on behalf of `scope` and returns `{:ok, task}` as it was before it was deleted. Returns
  `{:error, reason}` with nothing local deleted: `:not_discardable` for a task gone, cleaned up, merged or part of a
  split, `:merging` while a merge waits on GitHub, `:task_busy` when a run is still settling, or GitHub's refusal.
  """
  def discard_task(%Scope{} = scope, %Task{} = task) do
    clear_branch(scope, task, fn %Task{} -> :ok end, &wipe(scope, &1))
  end

  # Files and runs cannot be rolled back, so they go first; a task left with no runs can be discarded again.
  defp wipe(scope, %Task{issue: issue} = task) do
    :ok = Pipeline.purge_task(task)

    {:ok, reset} =
      Repo.transaction(fn ->
        :ok = Learnings.delete_task_observations(task)
        Repo.delete!(task)
        {:ok, reset} = reset_ticket(issue)
        reset
      end)

    # A finished ticket keeps its status, so the issue page is told its task is gone on its own.
    Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_changed, issue.id})
    broadcast_pipeline_changed(task)
    Phoenix.PubSub.broadcast(Rail.PubSub, "sandboxes", :sandboxes_changed)
    # An adopted pull request is closed now, so the issue lets its link go and offers Plan.
    if is_integer(reset.pr_number), do: Issues.link_pull_request(scope, reset)
    {:ok, task}
  end

  defp reset_ticket(%Issue{state: state} = issue) do
    if Issue.finished_state?(state), do: {:ok, issue}, else: Issues.reset_issue_state(issue, :todo)
  end
end
