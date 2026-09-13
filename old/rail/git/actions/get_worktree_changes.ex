defmodule Rail.Git.Actions.GetWorktreeChanges do
  @moduledoc false

  alias Rail.Git.WorktreeChanges

  @doc """
  Returns aggregate worktree changes against base branch or uncommitted changes.
  """
  def get_worktree_changes(worktree_path, opts \\ []) when is_binary(worktree_path) do
    base_branch = Keyword.get(opts, :base_branch, "main")
    on_branch = Rail.Git.get_changed_files(worktree_path, filter: base_branch)

    if on_branch == [] do
      uncommitted = Rail.Git.get_changed_files(worktree_path, filter: "uncommitted")
      %WorktreeChanges{filter: "uncommitted", files: uncommitted}
    else
      %WorktreeChanges{filter: base_branch, files: on_branch}
    end
  end
end
