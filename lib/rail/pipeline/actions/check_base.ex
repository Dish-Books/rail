defmodule Rail.Pipeline.Actions.CheckBase do
  @moduledoc """
  Records how a task's branch stands against the default branch as last fetched: behind it or not, and the files a
  merge would conflict in. The page offers Update on what this records, and everyone watching hears a change. A
  branch that was behind and now holds the default branch drops GitHub's last refusal, which was of the branch
  before it caught up.
  """

  import Rail.Pipeline.Utils.BroadcastPipelineChanged

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  @doc """
  Checks `task`'s branch against its project's default branch and saves what was found. Returns `{:ok, task}`. A
  task with no worktree is left as it is.
  """
  def check_base(%Task{} = task) do
    if Task.worktree_present?(task) do
      %Project{default_branch: base} = project = Repo.get!(Project, task.project_id)
      # A task's own clone reads the default its project's clone last fetched; one that fails reads the last copy.
      _copied = Git.copy_default_branch(project, task.worktree_path)
      %{behind: behind, conflicts: conflicts} = Git.base_status(task.worktree_path, base)
      changed? = {task.base_behind, task.base_conflicts} != {behind, conflicts}
      caught_up = if task.base_behind and not behind, do: %{merge_error: nil, merge_error_at: nil}, else: %{}

      {:ok, checked} =
        task
        |> Task.changeset(
          Map.merge(caught_up, %{base_behind: behind, base_conflicts: conflicts, base_checked_at: DateTime.utc_now()})
        )
        |> Repo.update()

      if changed?, do: broadcast_pipeline_changed(checked)
      {:ok, checked}
    else
      {:ok, task}
    end
  end
end
