defmodule Rail.Pipeline.Actions.RefreshMergeability do
  @moduledoc """
  Action to poll GitHub for pull request mergeability and draft status.
  Upholds invariants:
  - Unknown mergeability never withdraws a known conflict.
  - A nil draft status does not overwrite an existing boolean draft flag.
  - Skipped when there is no pull request or when the task is already merged.
  """

  import Rail.Pipeline.Utils.GitHubTokenResolver, only: [resolve_github_token: 3]

  alias Rail.GitHub
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Refreshes mergeability and draft status of a task's pull request.
  """
  def refresh_mergeability(scope, task_or_id, opts) when is_list(opts) do
    with :ok <- authorize_scope(scope),
         %Task{} = task <- resolve_task(task_or_id) do
      do_refresh(scope, task, opts)
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :not_found}
    end
  end

  def refresh_mergeability(task_or_id, opts) when is_list(opts) do
    refresh_mergeability(Scope.for_system(), task_or_id, opts)
  end

  def refresh_mergeability(scope, task_or_id) do
    refresh_mergeability(scope, task_or_id, [])
  end

  def refresh_mergeability(task_or_id) do
    refresh_mergeability(Scope.for_system(), task_or_id, [])
  end

  defp authorize_scope(%Scope{system: true}), do: :ok
  defp authorize_scope(%Scope{user: %{}}), do: :ok
  defp authorize_scope(nil), do: :ok
  defp authorize_scope(_scope), do: {:error, :not_authorized}

  defp do_refresh(_scope, %Task{stage: :merged} = task, _opts), do: {:ok, task}
  defp do_refresh(_scope, %Task{pr_number: nil} = task, _opts), do: {:ok, task}

  defp do_refresh(scope, %Task{} = task, opts) do
    case Repo.get(Project, task.project_id) do
      %Project{} = project ->
        poll_opts = Keyword.put_new(opts, :known_draft, task.pr_is_draft)

        with {:ok, token} <- resolve_github_token(scope, project, opts),
             {:ok, state} <- GitHub.pull_request_state(project.github_repo, task.pr_number, token, poll_opts) do
          apply_pr_state(task, state)
        end

      nil ->
        {:error, :project_not_found}
    end
  end

  defp apply_pr_state(%Task{} = task, %{mergeable: mergeable} = state) do
    resolved_mergeability =
      if mergeable == :unknown and task.mergeability == :conflicting do
        :conflicting
      else
        mergeable
      end

    attrs = %{
      mergeability: resolved_mergeability,
      pr_is_draft: Map.get(state, :is_draft, task.pr_is_draft)
    }

    {:ok, updated_task} =
      task
      |> Task.changeset(attrs)
      |> Repo.update()

    Rail.Pipeline.broadcast_pipeline_changed(%{
      task_id: updated_task.id,
      event: :mergeability_refreshed
    })

    {:ok, updated_task}
  end

  defp resolve_task(%Task{} = task), do: task
  defp resolve_task(id) when is_binary(id), do: Repo.get(Task, id)
  defp resolve_task(_other), do: nil
end
