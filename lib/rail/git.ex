defmodule Rail.Git do
  @moduledoc """
  Public context for Git worktrees, branches and fingerprints.

  A run works in a worktree of its own, so making one is on the path of every
  stage; reading diffs out of it was only ever for the diff viewer, and lives in
  `old/`.
  """

  alias Rail.Git.Actions

  defdelegate git_repo?(path), to: Actions.GitRepo
  defdelegate ensure_clone(clone_url, clone_path), to: Actions.EnsureClone
  defdelegate get_or_create_worktree(project, task), to: Actions.GetOrCreateWorktree
  defdelegate remove_worktree(repo_path, worktree_path, opts \\ []), to: Actions.RemoveWorktree
  defdelegate delete_branch(repo_path, branch, opts \\ []), to: Actions.DeleteBranch
  defdelegate branch_fingerprint(worktree_path), to: Actions.BranchFingerprint
end
