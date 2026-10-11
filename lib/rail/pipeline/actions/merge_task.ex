defmodule Rail.Pipeline.Actions.MergeTask do
  @moduledoc """
  A tech lead's Merge on Finalize: the merge is claimed and broadcast, so every tab shows Merging and a second
  click is refused, then the pull request is squash-merged on GitHub outside any transaction. A refusal is kept
  with GitHub's message; a merge records who and the sha, starts the parent's next children, and enters Merged.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.BroadcastPipelineChanged

  alias Rail.GitHub.Client, as: GitHub
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Workers.AdvanceSplit
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  @doc """
  Merges `task`'s pull request as the scope's tech lead. Returns `{:ok, task}` merged, or `{:error, reason}`:
  `{:merge_refused, message}` when GitHub turned it down, and otherwise for a project the scope cannot open
  or a task not at Finalize, not marked ready, already merging or already merged.
  """
  def merge_task(%Scope{} = scope, %Task{} = task) do
    task = Task |> Repo.get!(task.id) |> Repo.preload(:project)

    with true <- Scope.can_access_project?(scope, task.project_id) || {:error, :not_found},
         :ok <- claim(task) do
      # As claimed, so clearing the claim afterwards is a change the update writes.
      task = %{Repo.reload!(task) | project: task.project}
      broadcast_pipeline_changed(task)

      case merge(scope, task) do
        {:ok, sha} -> merged(scope, task, sha)
        {:error, reason} -> refused(task, reason)
      end
    end
  end

  # Taken in one statement, so of two clicks only one finds the task unclaimed; a claim older than a minute
  # is one whose caller died, and gives way.
  defp claim(%Task{} = task) do
    now = DateTime.utc_now()
    abandoned = DateTime.shift(now, second: -Task.merge_claim_seconds())

    {claimed, _rows} =
      Repo.update_all(
        from(t in Task,
          where:
            t.id == ^task.id and t.project_id == ^task.project_id and t.stage == :finalize and
              not is_nil(t.marked_ready_at) and is_nil(t.merged_at) and not is_nil(t.pr_number) and
              (is_nil(t.merge_started_at) or t.merge_started_at < ^abandoned)
        ),
        set: [merge_started_at: now, merge_error: nil, merge_error_at: nil]
      )

    if claimed == 1, do: :ok, else: {:error, unclaimable(task)}
  end

  # Read again, since what turned the claim away is what another tab did after this one loaded the task.
  defp unclaimable(%Task{} = task) do
    case Repo.reload!(task) do
      %Task{merged_at: %DateTime{}} -> :merged
      %Task{stage: stage} when stage != :finalize -> {:invalid_stage, stage}
      %Task{pr_number: nil} -> :no_pull_request
      %Task{marked_ready_at: nil} -> :not_ready
      %Task{} -> :merging
    end
  end

  # As the tech lead, like the pull request was opened as its owner, and as the app when they cannot.
  defp merge(%Scope{user: %User{github_token: token}}, %Task{project: %Project{} = project} = task)
       when is_binary(token) do
    case GitHub.merge_pull_request(token, project.github_repo, task.pr_number) do
      {:error, {:github_api_error, status, _body}} when status in [401, 403, 404] -> merge_as_app(task)
      result -> result
    end
  end

  defp merge(%Scope{}, %Task{} = task), do: merge_as_app(task)

  defp merge_as_app(%Task{project: %Project{} = project} = task) do
    with {:ok, token} <- GitHub.installation_token(project.github_installation_id) do
      GitHub.merge_pull_request(token, project.github_repo, task.pr_number)
    end
  end

  # The next children start without waiting on Linear to complete the issue, whose own job is the same one.
  defp merged(%Scope{} = scope, %Task{} = task, sha) do
    {:ok, task} =
      Repo.transaction(fn ->
        task =
          task
          |> Task.changeset(%{
            merged_at: DateTime.utc_now(),
            merged_by_id: scope.user && scope.user.id,
            merge_sha: sha,
            merge_started_at: nil
          })
          |> Repo.update!()

        if task.parent_task_id,
          do: {:ok, _job} = %{parent_task_id: task.parent_task_id} |> AdvanceSplit.new() |> Oban.insert()

        task
      end)

    Pipeline.enter_stage(task, :merged, start: false)
  end

  defp refused(%Task{} = task, reason) do
    message = message(reason)

    task
    |> Task.changeset(%{merge_error: message, merge_error_at: DateTime.utc_now(), merge_started_at: nil})
    |> Repo.update!()
    |> broadcast_pipeline_changed()

    {:error, {:merge_refused, message}}
  end

  defp message({:github_api_error, _status, %{"message" => message}}) when is_binary(message), do: message
  defp message({:github_api_error, status, _body}), do: "GitHub answered #{status}."
  defp message(reason), do: if(is_exception(reason), do: Exception.message(reason), else: inspect(reason))
end
