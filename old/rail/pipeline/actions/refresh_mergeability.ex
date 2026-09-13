defmodule Rail.Pipeline.Actions.RefreshMergeability do
  @moduledoc """
  Action to poll GitHub for pull request mergeability and draft status.
  Upholds invariants:
  - Unknown mergeability never withdraws a known conflict.
  - A nil draft status does not overwrite an existing boolean draft flag.
  - Skipped when there is no pull request or when the task is already merged.
  """

  import Rail.Pipeline.Utils.GitHubTokenResolver

  alias Rail.GitHub
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Refreshes mergeability and draft status of a task's pull request.
  """
  def refresh_mergeability(%Task{} = task, opts \\ []) do
    do_refresh(task, opts)
  end

  defp do_refresh(%Task{stage: :merged} = task, _opts), do: {:ok, task}

  defp do_refresh(%Task{pr_number: nil} = task, opts) do
    Rail.Pipeline.refresh_demo_freshness(task, opts)
  end

  defp do_refresh(%Task{} = task, opts) do
    case Repo.get(Project, task.project_id) do
      %Project{} = project ->
        poll_opts = Keyword.put_new(opts, :known_draft, task.pr_is_draft)

        with {:ok, token} <- resolve_github_token(Scope.for_system(), project, opts),
             {:ok, state} <- GitHub.pull_request_state(project.github_repo, task.pr_number, token, poll_opts) do
          apply_pr_state(task, state, opts)
        end

      nil ->
        {:error, :project_not_found}
    end
  end

  defp apply_pr_state(%Task{} = task, %{mergeable: mergeable} = state, opts) do
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

    Rail.Pipeline.refresh_demo_freshness(updated_task, opts)
  end
end
