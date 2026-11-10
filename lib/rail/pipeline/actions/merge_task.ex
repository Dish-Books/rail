defmodule Rail.Pipeline.Actions.MergeTask do
  @moduledoc """
  A tech lead's Merge on Finalize: the merge is claimed and broadcast, so every tab shows Merging and a second
  click is refused, then the pull request is squash-merged on GitHub outside any transaction. A refusal is kept
  with GitHub's message unless the pull request was merged there already, or was a draft, which is taken out of
  draft and merged once more. A kept refusal queues a check of the branch against a fresh fetch of the default
  branch, so Update shows when that is what stood in the way; a merge records who and the sha,
  starts the parent's next children, queues the task's cleanup and its owner's message, and enters Merged.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.BroadcastPipelineChanged

  alias Rail.GitHub.Client, as: GitHub
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Workers.AdvanceSplit
  alias Rail.Pipeline.Workers.CleanupMergedTask
  alias Rail.Pipeline.Workers.NotifyOwner
  alias Rail.Pipeline.Workers.RecheckBase
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User

  @doc """
  Merges `task`'s pull request as the scope's tech lead. Returns `{:ok, task}` merged, or `{:error, reason}`:
  `{:merge_refused, message}` when GitHub turned it down, and otherwise for a project the scope cannot open
  or a task not at Finalize, not marked ready, already merging or already merged.
  """
  def merge_task(%Scope{} = scope, %Task{} = task) do
    task = Task |> Repo.get!(task.id) |> Repo.preload(:project)

    with true <- Scope.can_access_project?(scope, task.project_id) || {:error, :not_found},
         :ok <- plan_approved(task),
         :ok <- claim(task) do
      # As claimed, so clearing the claim afterwards is a change the update writes.
      task = %{Repo.reload!(task) | project: task.project}
      broadcast_pipeline_changed(task)

      scope |> merge(task) |> settle(scope, task, :first)
    end
  end

  defp settle({:ok, sha}, %Scope{} = scope, %Task{} = task, _attempt),
    do: merged(task, %{merged_at: DateTime.utc_now(), merged_by_id: scope.user && scope.user.id, merge_sha: sha})

  # Nothing was asked of GitHub as anyone, so there is no refusal to keep: the claim is let go and the lead told.
  defp settle({:error, :no_github_token}, _scope, %Task{} = task, _attempt) do
    task |> Task.changeset(%{merge_started_at: nil}) |> Repo.update!() |> broadcast_pipeline_changed()
    {:error, :no_github_token}
  end

  defp settle({:error, reason}, %Scope{} = scope, %Task{} = task, attempt), do: read_refusal(scope, task, reason, attempt)

  # Work its owner started without approval merges only once a lead approved the plan. A task with no round
  # never had a plan to approve.
  defp plan_approved(%Task{} = task) do
    case Pipeline.list_rounds(task) do
      [%Round{approved_at: nil} | _later] -> {:error, :plan_not_approved}
      _approved_or_none -> :ok
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

  # As the tech lead, like the pull request was opened as its owner, and as the app when GitHub will not let them.
  # A lead GitHub does not know by their token signs in again rather than merging as the app.
  defp merge(%Scope{user: %User{}} = scope, %Task{project: %Project{} = project} = task) do
    with {:ok, token} <- Users.github_token(scope) do
      case GitHub.merge_pull_request(token, project.github_repo, task.pr_number) do
        {:error, {:github_api_error, 401, _body}} -> {:error, :no_github_token}
        {:error, {:github_api_error, status, _body}} when status in [403, 404] -> merge_as_app(task)
        result -> result
      end
    end
  end

  defp merge(%Scope{}, %Task{} = task), do: merge_as_app(task)

  defp merge_as_app(%Task{project: %Project{} = project} = task) do
    with {:ok, token} <- GitHub.installation_token(project.github_installation_id) do
      GitHub.merge_pull_request(token, project.github_repo, task.pr_number)
    end
  end

  # The next children start without waiting on Linear to complete the issue, whose own job is the same one.
  defp merged(%Task{} = task, merge) do
    {:ok, task} =
      Repo.transaction(fn ->
        task =
          task
          |> Task.changeset(Map.put(merge, :merge_started_at, nil))
          |> Repo.update!()

        if task.parent_task_id,
          do: {:ok, _job} = %{parent_task_id: task.parent_task_id} |> AdvanceSplit.new() |> Oban.insert()

        {:ok, _job} = %{task_id: task.id} |> CleanupMergedTask.new() |> Oban.insert()
        {:ok, _job} = %{task_id: task.id} |> NotifyOwner.new() |> Oban.insert()
        task
      end)

    Pipeline.enter_stage(task, :merged, start: false)
  end

  # The pull request is read before a refusal is kept, since what GitHub turns away may be merged there already,
  # or still a draft, which Rail opens it as and may have failed to take it out of once Review finished.
  defp read_refusal(%Scope{} = scope, %Task{project: %Project{} = project} = task, reason, attempt) do
    with {:ok, token} <- GitHub.installation_token(project.github_installation_id),
         {:ok, pull} <- GitHub.get_pull_request(token, project.github_repo, task.pr_number) do
      case pull do
        %{"merged" => true} -> merged_elsewhere(task, pull, reason)
        %{"draft" => true, "node_id" => "" <> node_id} when attempt == :first -> undraft(scope, task, token, node_id)
        _open -> refused(task, reason)
      end
    else
      _unread -> refused(task, reason)
    end
  end

  # Who merged it and when are GitHub's, not the clicker's, and a merger with no Rail account is left unnamed.
  defp merged_elsewhere(%Task{} = task, pull, reason) do
    with %{"merge_commit_sha" => "" <> sha, "merged_at" => "" <> at} <- pull,
         {:ok, merged_at, _offset} <- DateTime.from_iso8601(at) do
      merged(task, %{merged_at: merged_at, merged_by_id: merger_id(pull["merged_by"]), merge_sha: sha})
    else
      _unreadable -> refused(task, reason)
    end
  end

  # A draft is taken out of draft as the app, like Review does, and the merge asked for once more, still claimed.
  defp undraft(%Scope{} = scope, %Task{} = task, token, node_id) do
    case GitHub.mark_pull_request_ready(token, node_id) do
      :ok ->
        task = task |> Task.changeset(%{pr_is_draft: false}) |> Repo.update!()
        scope |> merge(task) |> settle(scope, task, :undrafted)

      {:error, reason} ->
        refused(task, {:still_draft, reason})
    end
  end

  defp merger_id(%{"login" => "" <> login}) do
    case Users.get_user(login: login) do
      {:ok, %User{id: id}} -> id
      {:error, :not_found} -> nil
    end
  end

  defp merger_id(_unknown), do: nil

  # The default branch moving under the pull request is the usual refusal, and Rail may not have fetched it yet, so
  # the branch is checked against a fresh fetch: when it is behind, Update shows beside the refusal.
  defp refused(%Task{} = task, reason) do
    message = message(reason)

    {:ok, task} =
      Repo.transaction(fn ->
        {:ok, _job} = %{task_id: task.id} |> RecheckBase.new() |> Oban.insert()

        task
        |> Task.changeset(%{merge_error: message, merge_error_at: DateTime.utc_now(), merge_started_at: nil})
        |> Repo.update!()
      end)

    broadcast_pipeline_changed(task)
    {:error, {:merge_refused, message}}
  end

  # GraphQL answers a mutation it turned down with 200 and its errors, rather than a status of its own.
  defp message({:still_draft, {:github_api_error, _status, %{"errors" => [%{"message" => "" <> said} | _rest]}}}),
    do: "The pull request is a draft, and GitHub would not take it out of draft: #{said}"

  defp message({:still_draft, reason}),
    do: "The pull request is a draft, and GitHub would not take it out of draft: #{message(reason)}"

  defp message({:github_api_error, _status, %{"message" => message}}) when is_binary(message), do: message
  defp message({:github_api_error, status, _body}), do: "GitHub answered #{status}."
  defp message(reason), do: if(is_exception(reason), do: Exception.message(reason), else: inspect(reason))
end
