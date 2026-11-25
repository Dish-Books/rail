defmodule Rail.Pipeline.Actions.RequestCoderabbitReview do
  @moduledoc """
  Asks CodeRabbit to review a task's pull request, with a comment from the asker's own GitHub account so the review is
  spent from their allowance. A pull request's first review reads it whole and a later one only the commits since.

  Asked at Finalize, the task goes back to Review and loses its ready mark, since its findings need ruling. Review
  then waits for CodeRabbit's answer before it can finish.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.BroadcastPipelineChanged
  import Rail.Pipeline.Utils.WithTaskLock
  import Rail.Pipeline.Utils.WriteReview

  alias Rail.Git
  alias Rail.GitHub.Client, as: GitHub
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.CoderabbitReview
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Workers.TimeOutCoderabbitReview
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User

  # CodeRabbit usually answers within a few minutes; a large pull request can take longer.
  @wait {20, :minutes}

  @doc """
  Asks CodeRabbit to review `task`'s pull request as the scope's user. Returns `{:ok, review}`, or an error for a task
  with no pull request or one a review cannot be asked on now, a review already waiting, or an asker with no GitHub
  token. GitHub's own refusal is `{:error, {:github_api_error, status, body}}`, and nothing is recorded.
  """
  def request_coderabbit_review(%Scope{user: %User{} = user} = scope, %Task{} = task) do
    with %Task{} = task <- Repo.get_by(Task, id: task.id, project_id: task.project_id),
         true <- Scope.can_access_project?(scope, task.project_id) || {:error, :not_found},
         {:ok, token} <- Users.github_token(scope) do
      with_task_lock(task.id, fn ->
        task = Repo.preload(Repo.reload!(task), [:project, :issue])

        with :ok <- requestable(task),
             {:ok, head} <- head(task) do
          request(task, user, token, head)
        end
      end)
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def request_coderabbit_review(%Scope{}, %Task{}), do: {:error, :no_github_token}

  defp requestable(%Task{} = task) do
    cond do
      task.cleaned_up_at != nil -> {:error, :cleaned_up}
      task.merged_at != nil -> {:error, :merged}
      task.stage not in [:review, :finalize] -> {:error, {:invalid_stage, task.stage}}
      task.pr_number == nil -> {:error, :no_pull_request}
      task.stage == :finalize and Task.finalize_state(task) == :merging -> {:error, :merging}
      pending?(task) -> {:error, :coderabbit_pending}
      true -> :ok
    end
  end

  defp head(%Task{} = task) do
    case Task.worktree_present?(task) && Git.branch_fingerprint(task.worktree_path)[:head_sha] do
      sha when is_binary(sha) -> {:ok, sha}
      _no_worktree -> {:error, :no_worktree}
    end
  end

  defp request(%Task{project: %Project{} = project} = task, %User{} = user, token, head) do
    command = if reviewed?(task), do: :incremental, else: :full
    round = task |> Pipeline.list_rounds() |> List.last()
    attrs = %{round: round.number, head_sha: head, command: command}

    {:ok, review} = task |> CoderabbitReview.request_changeset(user, attrs) |> Repo.insert()

    case GitHub.create_issue_comment(token, project.github_repo, task.pr_number, body(command)) do
      {:ok, %{"id" => comment_id}} ->
        {:ok, review} =
          review |> CoderabbitReview.status_changeset(:requested, %{external_id: comment_id}) |> Repo.update()

        if task.stage == :finalize, do: back_to_review(task)
        {:ok, _job} = %{review_id: review.id} |> TimeOutCoderabbitReview.new(schedule_in: @wait) |> Oban.insert()
        broadcast_pipeline_changed(task)
        {:ok, review}

      {:error, reason} ->
        Repo.delete!(review)
        {:error, reason}
    end
  end

  # Review's last pass is opened again, so the lead's turn on CodeRabbit's comments belongs to it and can finish it.
  defp back_to_review(%Task{} = task) do
    {:ok, _unmarked} = task |> Task.changeset(%{marked_ready_at: nil, marked_ready_by_id: nil}) |> Repo.update()
    passes = Pipeline.read_review(task)
    if passes != [], do: write_review(task, List.replace_at(passes, -1, %{List.last(passes) | finished_at: nil}))

    {:ok, _reviewing} = Pipeline.enter_stage(task, :review, start: false)
  end

  defp pending?(%Task{} = task) do
    Repo.exists?(
      from r in CoderabbitReview,
        where:
          r.task_id == ^task.id and r.project_id == ^task.project_id and r.status in ^CoderabbitReview.pending_statuses()
    )
  end

  # Only a review CodeRabbit finished has read the pull request, so after a skip or a failure it reads it whole again.
  defp reviewed?(%Task{} = task) do
    Repo.exists?(
      from r in CoderabbitReview, where: r.task_id == ^task.id and r.project_id == ^task.project_id and r.status == :done
    )
  end

  defp body(:full), do: "@coderabbitai full review"
  defp body(:incremental), do: "@coderabbitai review"
end
