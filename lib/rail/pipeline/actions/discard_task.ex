defmodule Rail.Pipeline.Actions.DiscardTask do
  @moduledoc """
  The task page's Discard: stops every run, closes the pull request, deletes the branch on GitHub and the
  task's files, and puts the ticket back to not started, so the issue can be started over on the same branch.

  GitHub goes before anything local, so a refusal there leaves the rest as it was and Discard again finishes.
  """

  import Ecto.Query

  alias Rail.Git
  alias Rail.GitHub.Client, as: GitHub
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Tools

  @doc """
  Discards `task` on behalf of `scope` and returns `{:ok, task}` cleaned up. Returns `{:error, reason}` with nothing
  local deleted: `:not_discardable` for a task cleaned up, merged or part of a split, `:merging` while a merge waits
  on GitHub, `:task_busy` when a run is still settling, or GitHub's refusal of the pull request or the branch.
  """
  def discard_task(%Scope{} = scope, %Task{id: id, project_id: project_id}) do
    task = Task |> Repo.get_by!(id: id, project_id: project_id) |> Repo.preload([:project, :issue, :runs])

    with :ok <- discardable(scope, task),
         :ok <- stop_runs(scope, task),
         :ok <- close_pull_request(task),
         :ok <- delete_branch(task),
         :ok <- close_questions(task),
         {:ok, cleaned} <- Pipeline.cleanup_task(task),
         {:ok, issue} <- reset_ticket(task.issue) do
      # An adopted pull request is closed now, so the issue lets its link go and offers Plan.
      if is_integer(issue.pr_number), do: Issues.link_pull_request(scope, issue)
      {:ok, cleaned}
    end
  end

  # A cleaned-up task refuses, so a second tab cannot move the ticket back under a task started since.
  defp discardable(scope, %Task{} = task) do
    cond do
      not Scope.can_access_project?(scope, task.project_id) -> {:error, :not_found}
      is_struct(task.cleaned_up_at, DateTime) or is_struct(task.merged_at, DateTime) -> {:error, :not_discardable}
      task.stage in [:merged, :split] or is_binary(task.parent_task_id) -> {:error, :not_discardable}
      task.stage == :finalize and Task.finalize_state(task) == :merging -> {:error, :merging}
      true -> :ok
    end
  end

  # A settle in flight can start CI or Review after a stop, so what is still live is read again.
  defp stop_runs(scope, %Task{} = task) do
    for run <- task.runs, Run.running?(run), do: {:ok, _stopped, _queued} = Pipeline.stop_run(scope, run)

    case Tools.list_os_processes(
           task_id: task.id,
           status: [:waiting_for_resources, :waiting_for_usage, :starting, :running]
         ) do
      [] -> :ok
      _live -> {:error, :task_busy}
    end
  end

  defp close_pull_request(%Task{pr_number: nil}), do: :ok

  defp close_pull_request(%Task{project: project, pr_number: number}) do
    with {:ok, token} <- GitHub.installation_token(project.github_installation_id),
         {:ok, %{"state" => "open"}} <- GitHub.get_pull_request(token, project.github_repo, number),
         {:ok, _closed} <- GitHub.update_pull_request(token, project.github_repo, number, %{state: "closed"}) do
      :ok
    else
      {:ok, _merged_or_closed} -> :ok
      {:error, reason} -> {:error, {:pull_request_not_closed, reason}}
    end
  end

  defp delete_branch(%Task{project: project, worktree_name: branch}) do
    case Git.delete_remote_branch(project, branch) do
      :ok -> :ok
      {:error, reason} -> {:error, {:branch_not_deleted, reason}}
    end
  end

  # Closed as a dismissed round is, so no run reads as waiting on a person once the task is gone.
  defp close_questions(%Task{id: task_id}) do
    now = DateTime.utc_now()

    {:ok, parked} =
      Repo.transaction(fn ->
        Repo.update_all(
          from(q in Question, where: q.task_id == ^task_id and q.status in [:asked, :pending]),
          set: [status: :dismissed, updated_at: now]
        )

        Repo.update_all(
          from(q in Question, where: q.task_id == ^task_id and is_nil(q.delivered_at)),
          set: [delivered_at: now, updated_at: now]
        )

        {_count, parked} =
          Repo.update_all(
            from(r in Run, where: r.task_id == ^task_id and r.status == :blocked_on_input, select: r.id),
            set: [status: :finished, updated_at: now]
          )

        parked
      end)

    for run_id <- parked, do: Phoenix.PubSub.broadcast(Rail.PubSub, "run:#{run_id}", {:run_changed, run_id})
    :ok
  end

  defp reset_ticket(%Issue{state: state} = issue) do
    if Issue.finished_state?(state), do: {:ok, issue}, else: Issues.reset_issue_state(issue)
  end
end
