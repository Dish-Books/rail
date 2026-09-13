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

  def merge_task(task, opts \\ [])

  def merge_task(%Task{stage: :merged} = task, _opts), do: {:ok, task}

  def merge_task(%Task{pr_number: nil}, _opts), do: {:error, :no_pr}

  def merge_task(%Task{pr_is_draft: true}, _opts) do
    {:error, :draft_pr}
  end

  def merge_task(%Task{mergeability: :conflicting} = task, opts) do
    if Keyword.get(opts, :ignore_conflicts, false) do
      execute_merge_flow(task, opts)
    else
      {:error, :has_conflicts}
    end
  end

  def merge_task(%Task{} = task, opts) do
    execute_merge_flow(task, opts)
  end

  defp execute_merge_flow(%Task{} = task, opts) do
    scope = Scope.for_system()

    case Repo.get(Project, task.project_id) do
      %Project{} = project ->
        with {:ok, token} <- resolve_github_token(scope, project, opts) do
          merge_opts = Keyword.put_new(opts, :merge_method, "squash")

          case execute_merge_with_verification(project, task, token, merge_opts) do
            :ok ->
              finalize_merge(project, task, token, opts)

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

  defp finalize_merge(project, task, token, opts) do
    _branch_res = GitHub.delete_remote_branch(project.github_repo, task.worktree_name, token, opts)

    if is_binary(project.clone_path) do
      _wt_res = Git.remove_worktree(project.clone_path, task.worktree_path)
    end

    maybe_transition_linear_issue(project, task)

    attrs = %{
      stage: :merged,
      merged_at: Keyword.get(opts, :merged_at) || DateTime.utc_now()
    }

    task
    |> Task.changeset(attrs)
    |> Repo.update()
  end

  defp maybe_transition_linear_issue(project, %Task{issue_id: issue_id}) when is_binary(issue_id) do
    %Issue{} = issue = Repo.get!(Issue, issue_id)
    owner_user = issue.owner_user_id && Repo.get(User, issue.owner_user_id)
    _issue_res = Issues.move_state(project, issue, :done, owner_user)
  end

  defp maybe_transition_linear_issue(_project, _task), do: :ok

  # The failure belongs to whoever asked for the merge, not to the task.
  defp handle_merge_failure(%Task{}, reason), do: {:error, reason}
end
