# Git

Owns git operations: cloning repositories, managing isolated task worktrees and branches, extracting diffs, synthesizing untracked changes, computing fingerprints, and commit histories.

## Language

**Worktree**:
An isolated git working copy on disk created for a specific task or agent run (under `<repo_root>/.worktrees/<name>`). Worktrees provide complete isolation so concurrent agents never contend on git locks, uncommitted working copy files, or branch checkouts.

**Branch**:
A git branch associated with a task (e.g. `axis/<identifier>`). Managed via worktrees during development and cleaned up upon task completion or PR merge.

**Fingerprint**:
A deterministic snapshot (`BranchFingerprint`) combining the `head_sha` (`git rev-parse HEAD`) and `dirty_digest` (SHA-256 of `git status --porcelain --untracked-files=all`). Used to detect if a worktree has drifted, whether committed or uncommitted.

**Synthetic Diff**:
A synthesized `diff --git` patch for untracked files not yet known to git index, allowing diff reviewers and QA gates to review newly created files before they are committed.

## Relationships

- **Git → ToolEnv**: All underlying git subprocess executions run through `Rail.ToolEnv.run/3` to ensure login shell PATH parity and consistent environment variables across macOS and Linux runner environments.
- **Git → Domain.Diff**: Exposes `parse_unified_diff/1` and `diff_text/3` by delegating to `Rail.Domain.Diff` parser and LCS diff engine.
- **Pipeline → Git**: The Pipeline context orchestrates tasks by creating worktrees via `get_or_create_worktree/3`, inspecting changes via `get_worktree_changes/2` and `get_diff/2`, and tearing down worktrees on merge via `remove_worktree/2` and `delete_branch/2`.
