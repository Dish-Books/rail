defmodule Rail.Pipeline.Utils.ClearBranch do
  @moduledoc """
  What Discard and Back to Plan share: stopping the task's runs, then, under the task's lock, closing its pull
  request and deleting its branch on GitHub before the caller erases the rest.

  GitHub goes before anything local, so a refusal there leaves the rest as it was and trying again finishes.
  """

  import Rail.Pipeline.Utils.WithTaskLock

  alias Rail.Git
  alias Rail.GitHub.Client, as: GitHub
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Tools

  @doc """
  Runs `erase` on `task` as read again under its lock, once `allowed` and the checks both actions share pass, its
  runs are stopped and GitHub has let its pull request and branch go. Returns what `erase` does, or `{:error, reason}`.
  """
  def clear_branch(%Scope{} = scope, %Task{id: id, project_id: project_id}, allowed, erase)
      when is_function(allowed, 1) and is_function(erase, 1) do
    task = read(id, project_id)

    with :ok <- clearable(scope, task, allowed) do
      # Outside the lock: a stop settles its run through a finish that takes no lock, and waits on it.
      stop_runs(scope, task)

      with_task_lock(id, fn ->
        task = read(id, project_id)

        with :ok <- clearable(scope, task, allowed),
             :ok <- idle(task),
             :ok <- close_pull_request(task),
             :ok <- delete_branch(task),
             do: erase.(task)
      end)
    end
  end

  defp read(id, project_id) do
    case Repo.get_by(Task, id: id, project_id: project_id) do
      %Task{} = task -> Repo.preload(task, [:project, :issue, :rounds, runs: [:role, :questions]])
      nil -> nil
    end
  end

  # A cleaned-up task refuses, so a second tab cannot move the ticket back under a task started since.
  defp clearable(_scope, nil, _allowed), do: {:error, :not_discardable}

  defp clearable(scope, %Task{} = task, allowed) do
    cond do
      not Scope.can_access_project?(scope, task.project_id) -> {:error, :not_found}
      is_struct(task.cleaned_up_at, DateTime) or is_struct(task.merged_at, DateTime) -> {:error, :not_discardable}
      task.stage in [:merged, :split] or is_binary(task.parent_task_id) -> {:error, :not_discardable}
      task.stage == :finalize and Task.finalize_state(task) == :merging -> {:error, :merging}
      true -> allowed.(task)
    end
  end

  defp stop_runs(scope, %Task{} = task) do
    for run <- task.runs, Run.running?(run), do: {:ok, _stopped, _queued} = Pipeline.stop_run(scope, run)
  end

  # A settle in flight can start CI or Review after a stop, so what is still live is read again under the lock.
  defp idle(%Task{} = task) do
    live =
      Tools.list_os_processes(task_id: task.id, status: [:waiting_for_resources, :waiting_for_usage, :starting, :running])

    if Task.running?(task) or live != [], do: {:error, :task_busy}, else: :ok
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
end
