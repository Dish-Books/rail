defmodule Rail.Pipeline.Actions.CreateTask do
  @moduledoc """
  Creates the pipeline task for an issue, at the stage it should start from.

  The task carries only its own pipeline state: the title, description and
  owner stay on the issue it links to. The issue's own state is left alone —
  the engineer stage is what moves it to `:in_progress`. Returns the existing
  task when the issue already has one.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  @doc """
  Creates or returns the task for `issue`, starting it at `stage`.
  """
  def create_task(%Issue{project: %Project{} = project} = issue, stage) do
    case Repo.get_by(Task, issue_id: issue.id) do
      %Task{} = task -> {:ok, task}
      nil -> do_create(project, issue, stage)
    end
  end

  defp do_create(%Project{} = project, %Issue{} = issue, stage) do
    name = worktree_name(issue)

    attrs = %{
      issue_id: issue.id,
      stage: stage,
      stage_state: :queued,
      worktree_name: name,
      worktree_path: Path.join(project.clone_path, ".worktrees/#{name}")
    }

    case %Task{} |> Task.changeset(attrs, project.id) |> Repo.insert() do
      {:ok, task} ->
        Pipeline.broadcast_pipeline_changed(%{task_id: task.id, event: :task_created})
        {:ok, task}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp worktree_name(%Issue{branch_name: branch}) when is_binary(branch) and branch != "", do: branch

  defp worktree_name(%Issue{identifier: identifier}) when is_binary(identifier) do
    identifier |> String.downcase() |> String.replace(~r/[^a-z0-9_-]/i, "-")
  end
end
