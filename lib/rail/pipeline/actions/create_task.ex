defmodule Rail.Pipeline.Actions.CreateTask do
  @moduledoc """
  Creates the pipeline task for an issue, at the `:product` stage.

  Moves the issue to `:in_progress` and hands the task to whoever the issue is
  assigned to. Returns the existing task when the issue already has one.
  """

  import Ecto.Query

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  @doc """
  Creates or returns the task for `issue`.
  """
  def create_task(%Issue{project: %Project{} = project} = issue) do
    case Repo.one(from t in Task, where: t.issue_id == ^issue.id, limit: 1) do
      %Task{} = task -> {:ok, task}
      nil -> do_create(project, issue)
    end
  end

  defp do_create(%Project{} = project, %Issue{} = issue) do
    owner_user = issue.owner_user_id && Repo.get(User, issue.owner_user_id)

    with {:ok, _issue} <- Issues.move_state(Scope.for_system(), project, issue, :in_progress, owner_user) do
      attrs = %{
        issue_id: issue.id,
        owner_user_id: issue.owner_user_id,
        title: issue.title,
        description: issue.description,
        stage: :product,
        stage_state: :queued,
        worktree_name: worktree_name(issue)
      }

      case %Task{} |> Task.changeset(attrs, project.id) |> Repo.insert() do
        {:ok, task} ->
          Pipeline.broadcast_pipeline_changed(%{task_id: task.id, event: :task_created})
          {:ok, task}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  defp worktree_name(%Issue{branch_name: branch}) when is_binary(branch) and branch != "", do: branch

  defp worktree_name(%Issue{identifier: identifier}) when is_binary(identifier) do
    identifier |> String.downcase() |> String.replace(~r/[^a-z0-9_-]/i, "-")
  end
end
