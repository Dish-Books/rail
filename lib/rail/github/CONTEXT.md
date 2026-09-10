# GitHub

Owns GitHub API interactions, GitHub App authentication and installation access token exchange, pull request state polling with mergeability retry handling, and user-attributed pull request lifecycle operations (squash merge, marking ready for review, remote branch deletion).

## Language

**GitHub App Installation Token**:
A short-lived access token exchanged from GitHub via `POST /app/installations/:installation_id/access_tokens` using an RS256 JWT signed with the GitHub App's private key. Used by background polls and agent runs (`GH_TOKEN`, git credential helper).

**User OAuth Token**:
The acting human user's GitHub personal OAuth access token (from GitHub OAuth login). Per Decision **D6**, human-driven lifecycle actions—merging a PR, marking a draft PR ready for review, and deleting the remote branch—must use the user's token so GitHub properly attributes these actions to the human rather than the app bot.

**Mergeability (`:mergeable` | `:conflicting` | `:unknown`)**:
GitHub calculates PR mergeability asynchronously in the background. Immediately after a push, GitHub commonly reports `mergeable: null` (`:unknown`). The client employs a retry loop (3 attempts with configurable delay) to wait for GitHub's lazy calculation before settling on `:unknown`.

**Squash Merge**:
PRs are merged using GitHub's REST API with `merge_method: "squash"`, without `--delete-branch`, leaving local worktrees intact until pipeline cleanup tears down the worktree and branch.

**Mark Ready**:
Engineers create pull requests in draft mode. Promoting a draft PR to ready for review is an explicit user action performed via GitHub's GraphQL mutation `markPullRequestReady`.

**Remote Branch Deletion**:
Deleting a remote branch via `DELETE /repos/:owner/:repo/git/refs/heads/:branch` is idempotent: an HTTP 404 (indicating the branch was already deleted or does not exist) is treated as successful completion (`:ok`).

## Relationships

- **Pipeline → GitHub**: The Pipeline context orchestrates tasks by monitoring pull request mergeability and draft status via `pull_request_state/4`, checking merged status via `pull_request_is_merged/4`, promoting draft PRs via `mark_pull_request_ready/4`, executing squash merges via `merge_pull_request/4`, resolving branch PR numbers via `pull_request_number_for_branch/4`, and deleting remote branches via `delete_remote_branch/4`.
- **Projects → GitHub**: Projects may discover available repositories for an installation via `list_installation_repositories/2`.
- **GitHub → ToolEnv / Git**: Installation tokens obtained via `installation_token/2` are supplied to Git operations and agent run environments (`GH_TOKEN`).
