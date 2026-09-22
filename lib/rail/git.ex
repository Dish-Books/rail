defmodule Rail.Git do
  @moduledoc """
  Public context for Git: the worktree a run works in, the commits Rail makes out
  of it, and the diff a human reads it back as.

  A run works in a worktree of its own, so making one is on the path of every
  stage. Committing and pushing are Rail's job rather than the agent's: the
  identity a commit carries and the key it is signed with are decisions Rail
  makes, not ones an agent should be trusted to get right — so the actions that
  commit and push resolve the identity, the signing key and the push credential
  themselves rather than taking them from a caller. Reading the result is the
  other half of the same thing, so parsing a diff and remembering who has read
  which file of it live here too.
  """

  alias Rail.Git.Actions

  defdelegate git_repo?(path), to: Actions.GitRepo
  defdelegate ensure_clone(clone_url, clone_path), to: Actions.EnsureClone
  defdelegate get_or_create_worktree(project, task), to: Actions.GetOrCreateWorktree
  defdelegate remove_worktree(repo_path, worktree_path, opts \\ []), to: Actions.RemoveWorktree
  defdelegate delete_branch(repo_path, branch, opts \\ []), to: Actions.DeleteBranch
  defdelegate branch_fingerprint(worktree_path), to: Actions.BranchFingerprint

  defdelegate worktree_dirty?(worktree_path), to: Actions.WorktreeDirty
  defdelegate branch_unpushed?(worktree_path), to: Actions.BranchUnpushed
  defdelegate commit_worktree(scope, task, message), to: Actions.CommitWorktree
  defdelegate push_branch(scope, task), to: Actions.PushBranch
  defdelegate credential_env(project), to: Actions.CredentialEnv
  defdelegate fetch_default_branch(project, worktree_path), to: Actions.FetchDefaultBranch
  defdelegate rebased_onto?(worktree_path, base_branch), to: Actions.RebasedOnto
  defdelegate rebase_in_progress?(worktree_path), to: Actions.RebaseInProgress
  defdelegate conflicted_files(worktree_path), to: Actions.ConflictedFiles
  defdelegate rebase_branch(scope, task), to: Actions.RebaseBranch

  defdelegate load_diff(scope, task, filter \\ :branch), to: Actions.LoadDiff
  defdelegate load_diff_hunk(scope, task, path, line \\ nil), to: Actions.LoadDiffHunk
  defdelegate expand_diff_gap(task, path, gap_index, start_line, end_line), to: Actions.ExpandDiffGap
  defdelegate list_viewed_files(scope, task), to: Actions.ListViewedFiles
  defdelegate set_file_viewed(scope, task, path, digest, viewed), to: Actions.SetFileViewed
end
