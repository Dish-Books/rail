defmodule Rail.Git do
  @moduledoc """
  Public context for Git operations, worktrees, branches, diffs, and fingerprints.
  """

  alias Rail.Domain.Diff.TextLineDiff
  alias Rail.Domain.Diff.UnifiedDiffParser
  alias Rail.Git.Actions

  defdelegate ensure_clone(clone_url, clone_path), to: Actions.EnsureClone
  defdelegate get_or_create_worktree(project, task), to: Actions.GetOrCreateWorktree
  defdelegate remove_worktree(repo_path, worktree_path, opts \\ []), to: Actions.RemoveWorktree
  defdelegate delete_branch(repo_path, branch, opts \\ []), to: Actions.DeleteBranch
  defdelegate get_diff(worktree_path), to: Actions.GetDiff
  defdelegate get_diff(worktree_path, filter), to: Actions.GetDiff
  defdelegate list_untracked_files(worktree_path), to: Actions.ListUntrackedFiles
  defdelegate synthesize_untracked_diff(worktree_path, relative_path), to: Actions.SynthesizeUntrackedDiff
  defdelegate get_worktree_changes(worktree_path, opts \\ []), to: Actions.GetWorktreeChanges
  defdelegate get_changed_files(worktree_path, opts \\ []), to: Actions.GetChangedFiles
  defdelegate branch_fingerprint(worktree_path), to: Actions.BranchFingerprint
  defdelegate head_sha(worktree_path), to: Actions.HeadSha
  defdelegate file_lines(worktree_path, relative_path, opts \\ []), to: Actions.FileLines
  defdelegate list_worktrees(repo_path), to: Actions.ListWorktrees
  defdelegate recent_commits(worktree_path, opts \\ []), to: Actions.RecentCommits

  defdelegate parse_unified_diff(diff_text), to: UnifiedDiffParser, as: :parse
  defdelegate diff_text(before_text, after_text, path), to: TextLineDiff, as: :diff
end
