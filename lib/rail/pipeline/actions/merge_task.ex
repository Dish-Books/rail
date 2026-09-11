defmodule Rail.Pipeline.Actions.MergeTask do
  @moduledoc """
  Action to squash-merge a task's pull request.
  Upon merge, deletes the remote branch, removes the local worktree,
  transitions the Linear issue to Done, and marks the task as merged.
  """

  import Rail.Pipeline.Utils.GitHubTokenResolver

  alias Rail.Git
  alias Rail.GitHub
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  @doc """
  Squash-merges a task's pull request and finalizes its branch and Linear state.
  """
  def merge_task(scope, task_or_id, opts) when is_list(opts) do
    with :ok <- authorize_scope(scope),
         %Task{} = task <- resolve_task(task_or_id) do
      do_merge_task(scope, task, opts)
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :not_found}
    end
  end

  def merge_task(task_or_id, opts) when is_list(opts) do
    merge_task(Scope.for_system(), task_or_id, opts)
  end

  def merge_task(scope, task_or_id) do
    merge_task(scope, task_or_id, [])
  end

  def merge_task(task_or_id) do
    merge_task(Scope.for_system(), task_or_id, [])
  end

  defp authorize_scope(%Scope{system: true}), do: :ok
  defp authorize_scope(%Scope{user: %{}}), do: :ok
  defp authorize_scope(nil), do: :ok
  defp authorize_scope(_scope), do: {:error, :not_authorized}

  defp do_merge_task(_scope, %Task{stage: :merged} = task, _opts), do: {:ok, task}

  defp do_merge_task(_scope, %Task{pr_number: nil}, _opts), do: {:error, :no_pr}

  defp do_merge_task(_scope, %Task{pr_is_draft: true}, _opts) do
    {:error, :draft_pr}
  end

  defp do_merge_task(scope, %Task{mergeability: :conflicting} = task, opts) do
    if Keyword.get(opts, :ignore_conflicts, false) do
      execute_merge_flow(scope, task, opts)
    else
      {:error, :has_conflicts}
    end
  end

  defp do_merge_task(scope, %Task{} = task, opts) do
    execute_merge_flow(scope, task, opts)
  end

  defp execute_merge_flow(scope, %Task{} = task, opts) do
    case Repo.get(Project, task.project_id) do
      %Project{} = project ->
        with {:ok, token} <- resolve_github_token(scope, project, opts) do
          merge_opts = Keyword.put_new(opts, :merge_method, "squash")

          case execute_merge_with_verification(project, task, token, merge_opts) do
            :ok ->
              finalize_merge(scope, project, task, token, opts)

            {:error, reason} ->
              handle_merge_failure(task, reason)
          end
        end

      nil ->
        {:error, :project_not_found}
    end
  end

  defp execute_merge_with_verification(project, task, token, merge_opts) do
    case GitHub.merge_pull_request(project.github_repo, task.pr_number, token, merge_opts) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        case GitHub.pull_request_is_merged(project.github_repo, task.pr_number, token, merge_opts) do
          {:ok, true} -> :ok
          _other -> {:error, reason}
        end
    end
  end

  defp finalize_merge(scope, project, task, token, opts) do
    _branch_res = GitHub.delete_remote_branch(project.github_repo, task.worktree_name, token, opts)

    if is_binary(project.clone_path) do
      _wt_res = Git.remove_worktree(project.clone_path, task.worktree_path)
    end

    maybe_transition_linear_issue(scope, project, task)

    attrs = %{
      stage: :merged,
      merged_at: Keyword.get(opts, :merged_at) || DateTime.utc_now(),
      error: nil
    }

    {:ok, updated_task} =
      task
      |> Task.changeset(attrs)
      |> Repo.update()

    Rail.Pipeline.broadcast_pipeline_changed(%{
      task_id: updated_task.id,
      event: :task_merged
    })

    {:ok, updated_task}
  end

  defp maybe_transition_linear_issue(scope, project, %Task{issue_id: issue_id}) when is_binary(issue_id) do
    %Issue{} = issue = Repo.get!(Issue, issue_id)
    owner_user = issue.owner_user_id && Repo.get(User, issue.owner_user_id)
    effective_scope = scope || Scope.for_system()
    _issue_res = Issues.move_state(effective_scope, project, issue, :done, owner_user)
  end

  defp maybe_transition_linear_issue(_scope, _project, _task), do: :ok

  defp handle_merge_failure(%Task{} = task, reason) do
    error_msg = "Failed to merge pull request: #{format_reason(reason)}"

    {:ok, updated_task} =
      task
      |> Task.changeset(%{error: error_msg})
      |> Repo.update()

    Rail.Pipeline.broadcast_pipeline_changed(%{
      task_id: updated_task.id,
      event: :merge_failed
    })

    {:error, reason}
  end

  defp format_reason({:github_api_error, _status, %{"message" => msg}}), do: msg
  defp format_reason({:github_api_error, status, msg}) when is_binary(msg), do: "#{status} #{msg}"
  defp format_reason(reason), do: inspect(reason)

  defp resolve_task(%Task{} = task), do: task
  defp resolve_task(id) when is_binary(id), do: Repo.get(Task, id)
  defp resolve_task(_other), do: nil
end
