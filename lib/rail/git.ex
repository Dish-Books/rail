defmodule Rail.Git do
  @moduledoc """
  Public context for Git: the worktree a run works in, the identity its agent
  commits as, and the diff a human reads it back as.

  A run works in a worktree of its own, so making one is on the path of every
  stage. The agent commits there itself, as the ticket's owner and signed with
  their key, which Rail writes into the worktree's config for the turn and takes
  out again after it. Pushing stays Rail's, since the credential is the project's.
  Reading the result is the other half of the same thing, so parsing a diff and
  remembering who has read which file of it live here too.
  """

  alias Rail.Git.Actions

  defdelegate git_repo?(path), to: Actions.GitRepo
  defdelegate ensure_clone(clone_url, clone_path), to: Actions.EnsureClone
  defdelegate get_or_create_worktree(project, task), to: Actions.GetOrCreateWorktree
  defdelegate checkout_detached_worktree(project, worktree_path), to: Actions.CheckoutDetachedWorktree
  defdelegate remove_worktree(repo_path, worktree_path, opts \\ []), to: Actions.RemoveWorktree
  defdelegate delete_branch(repo_path, branch, opts \\ []), to: Actions.DeleteBranch
  defdelegate branch_fingerprint(worktree_path), to: Actions.BranchFingerprint
  defdelegate content_fingerprint(worktree_path), to: Actions.ContentFingerprint

  defdelegate worktree_dirty?(worktree_path), to: Actions.WorktreeDirty
  defdelegate list_changed_paths(worktree_path), to: Actions.ListChangedPaths
  defdelegate load_branch_history(task, rounds \\ []), to: Actions.LoadBranchHistory
  defdelegate branch_unpushed?(worktree_path), to: Actions.BranchUnpushed
  defdelegate branch_changed?(task), to: Actions.BranchChanged
  defdelegate push_branch(scope, task), to: Actions.PushBranch
  defdelegate set_commit_identity(task), to: Actions.SetCommitIdentity
  defdelegate clear_commit_identity(task), to: Actions.ClearCommitIdentity
  defdelegate credential_env(project), to: Actions.CredentialEnv
  defdelegate ci_env(project, task), to: Actions.CiEnv
  defdelegate fetch_default_branch(project, worktree_path), to: Actions.FetchDefaultBranch
  defdelegate read_default_branch_file(project, path), to: Actions.ReadDefaultBranchFile

  # `filter` is `:branch`, `:uncommitted`, or `{:commit, sha}` for one commit against its first parent.
  defdelegate load_diff(scope, task, filter \\ :branch, previous_files \\ []), to: Actions.LoadDiff
  defdelegate load_diff_hunk(scope, task, path, line \\ nil), to: Actions.LoadDiffHunk

  defdelegate expand_diff_gap(task, path, gap_index, start_line, end_line, revision \\ :worktree),
    to: Actions.ExpandDiffGap

  defdelegate list_viewed_files(scope, task), to: Actions.ListViewedFiles
  defdelegate set_file_viewed(scope, task, path, digest, viewed), to: Actions.SetFileViewed
end
