defmodule Rail.Pipeline.Actions.MarkPrReady do
  @moduledoc """
  Action to mark a GitHub pull request as ready for review.
  Promotes draft pull requests, clears errors, and initiates a mergeability refresh.
  """

  import Rail.Pipeline.Utils.GitHubTokenResolver, only: [resolve_github_token: 3]

  alias Rail.GitHub
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Marks a draft pull request as ready for review.
  """
  def mark_pr_ready(scope, task_or_id, opts) when is_list(opts) do
    with :ok <- authorize_scope(scope),
         %Task{} = task <- resolve_task(task_or_id) do
      do_mark_pr_ready(scope, task, opts)
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :not_found}
    end
  end

  def mark_pr_ready(task_or_id, opts) when is_list(opts) do
    mark_pr_ready(Scope.for_system(), task_or_id, opts)
  end

  def mark_pr_ready(scope, task_or_id) do
    mark_pr_ready(scope, task_or_id, [])
  end

  def mark_pr_ready(task_or_id) do
    mark_pr_ready(Scope.for_system(), task_or_id, [])
  end

  defp authorize_scope(%Scope{system: true}), do: :ok
  defp authorize_scope(%Scope{user: %{}}), do: :ok
  defp authorize_scope(nil), do: :ok
  defp authorize_scope(_scope), do: {:error, :not_authorized}

  defp do_mark_pr_ready(_scope, %Task{pr_number: nil} = task, _opts) do
    error_msg = "This task has no pull request to mark ready."

    {:ok, updated_task} =
      task
      |> Task.changeset(%{error: error_msg})
      |> Repo.update()

    Rail.Pipeline.broadcast_pipeline_changed(%{
      task_id: updated_task.id,
      event: :mark_pr_ready_failed
    })

    {:error, :no_pr}
  end

  defp do_mark_pr_ready(scope, %Task{} = task, opts) do
    case Repo.get(Project, task.project_id) do
      %Project{} = project ->
        with {:ok, token} <- resolve_github_token(scope, project, opts) do
          case GitHub.mark_pull_request_ready(project.github_repo, task.pr_number, token, opts) do
            {:ok, _result} ->
              handle_mark_ready_success(scope, task, opts)

            {:error, reason} ->
              handle_mark_ready_failure(task, reason)
          end
        end

      nil ->
        {:error, :project_not_found}
    end
  end

  defp handle_mark_ready_success(scope, %Task{} = task, opts) do
    attrs = %{
      pr_is_draft: false,
      error: nil
    }

    {:ok, updated_task} =
      task
      |> Task.changeset(attrs)
      |> Repo.update()

    Rail.Pipeline.broadcast_pipeline_changed(%{
      task_id: updated_task.id,
      event: :pr_marked_ready
    })

    Rail.Pipeline.refresh_mergeability(scope, updated_task, opts)
  end

  defp handle_mark_ready_failure(%Task{} = task, reason) do
    error_msg = "Failed to mark pull request ready: #{format_reason(reason)}"

    {:ok, updated_task} =
      task
      |> Task.changeset(%{error: error_msg})
      |> Repo.update()

    Rail.Pipeline.broadcast_pipeline_changed(%{
      task_id: updated_task.id,
      event: :mark_pr_ready_failed
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
