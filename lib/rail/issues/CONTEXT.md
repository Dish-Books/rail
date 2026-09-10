# Issues Context

The `Issues` context manages issues mirrored from Linear. It owns the local issue mirror (`issues` table), synchronization with Linear GraphQL API, capturing issues, ticket push-backs from agents, split ticket creation, issue state transitions, comments, and asset uploads.

## Key Decisions & Domain Rules
- **Two Linear Identities (D7)**:
  - User OAuth tokens (`actor=user`) are stored encrypted on `users`.
  - Linear writes with a human behind them use that human's token (capture -> capturer; ticket push, splits, state moves, comments -> task owner).
  - Fallback to workspace token (`linear_workspaces.token`) if owner/capturer is unlinked, logged as `[axis] pushed to Linear as the workspace`.
  - Workspace token covers background sync, webhook reads, and asset uploads.
- **Single Source of Truth**: Linear is the external issue tracker; Rail maintains a local read mirror in the `issues` table.
- **States**: Mapped to `Rail.Domain.Enums.IssueState` (`:triage`, `:backlog`, `:in_progress`, `:done`, `:canceled`).

## Public API
- `sync_issues(scope, project)`: fetches issues from Linear updated since last sync, maps states, upserts local rows.
- `capture_issue(scope, project, ask)`: derives title via `summarize_ask`, creates issue in Linear in Triage state, mirrors locally.
- `get_issue(scope, id)` / `get_issue!(scope, id)` / `list_issues(scope, project_or_opts)`: read queries.
- `update_issue(scope, issue, attrs)`: updates title, description, or state in Linear and locally.
- `archive_issue(scope, issue)`: marks canceled in Linear and locally.
- `push_ticket(scope, project, identifier, ticket_content, owner_user \\ nil)`: parses `# Title` ticket markdown, updates Linear and local mirror.
- `create_split_issues(scope, project, split_tickets, owner_user \\ nil)`: creates Linear issues in Triage state for each split ticket.
- `move_state(scope, project, issue, state_type, owner_user \\ nil)`: transitions issue state in Linear and updates local mirror.
- `upload_asset(scope, filename, content_type, data_binary, opts \\ [])`: uploads binary asset to Linear using workspace token.
- `comment(scope, issue, comment_body, owner_user \\ nil)`: posts comment to Linear issue.
