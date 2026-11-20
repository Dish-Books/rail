defmodule Rail.Pipeline.Utils.PrepareWorktree do
  @moduledoc """
  Gets a task's worktree ready to work in: a slot of ports of its own, and the
  checkout itself.
  """

  import Rail.Pipeline.Utils.ClaimWorktreeSlot

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project

  @doc """
  Claims `task` a worktree slot if it has none, then gets or creates its worktree.

  Returns `{:ok, task, worktree_path}` with the task as it now stands.
  """
  def prepare_worktree(%Project{} = project, %Task{} = task) do
    with {:ok, task} <- claim_worktree_slot(task),
         {:ok, worktree_path} <- Git.get_or_create_worktree(project, task) do
      {:ok, task, worktree_path}
    end
  end
end
