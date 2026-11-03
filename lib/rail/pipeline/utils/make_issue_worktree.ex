defmodule Rail.Pipeline.Utils.MakeIssueWorktree do
  @moduledoc """
  Makes the worktree a start's task will work in before the task exists, so no transaction is open while git fetches:
  a fetch can outlast the pool's hold on a connection. The path is drawn from the issue alone, so the task the start
  then records finds its worktree there, and a start that fails after this leaves one the next start reuses.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.BuildTask

  alias Ecto.Changeset
  alias Rail.Git
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  @doc """
  Gets or creates the worktree for `issue`'s task in `project` and returns `{:ok, worktree_path}`, or
  `{:error, :task_exists}` for an issue with a live task, with no git asked, or `{:error, {:worktree_failed, reason}}`.
  """
  def make_issue_worktree(%Project{} = project, %Issue{} = issue) do
    if Repo.exists?(from(t in Task, where: t.issue_id == ^issue.id and is_nil(t.cleaned_up_at))) do
      {:error, :task_exists}
    else
      task = project |> build_task(issue, %{}) |> Changeset.apply_changes()

      case Git.get_or_create_worktree(project, task) do
        {:ok, worktree_path} -> {:ok, worktree_path}
        {:error, reason} -> {:error, {:worktree_failed, reason}}
      end
    end
  end
end
