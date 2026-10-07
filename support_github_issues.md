# Support GitHub Issues as an issue tracker

Goal: a project can use GitHub Issues instead of Linear, so a project with no Linear account works end to end (capture, product, design, architect, engineer, review, QA, demo, PR, done). Linear stays fully supported; the choice is per project.

Verified against `main` at `b0f8bf0`. Rules followed: `docs/standards.md`, `docs/tests.md` (actions are one public function behind a `defdelegate`, utils are one public function and imported, clients only call the API, no per-file test helpers, `Req.Test` for HTTP).

## Revised after review (2026-10-07)

What was built differs from the plan below in two ways:

- **No polling.** GitHub changes arrive through the App's webhook (`POST /webhooks/github`, signed with `GITHUB_WEBHOOK_SECRET`), as Linear's do. `GithubSync` is only the Sync button's full pull, like `LinearSync`. There is no cron. On a laptop, deliveries come through a relay such as smee.io (see `docs/org-setup.md`).
- **An adapter, not function clauses.** `Rail.Issues.Tracker` is a behaviour (create, update, advance, comment, import, sync, set up, assets, who can be assigned), implemented by `Rail.Issues.Tracker.Linear` and `Rail.Issues.Tracker.Github` and picked through `config :rail, :issue_trackers`. The actions and workers only call the tracker. Tests run through Mox mocks of the behaviour, stubbed with the real trackers by default.

---

## 0. TL;DR

- Add `projects.tracker` (`:linear | :github`, default `:linear`) and `issues.tracker`. Linear columns stay, but are only required when `tracker: :linear`.
- No behaviour module. Each existing Issues action or worker that talks to Linear gets a `%Project{tracker: :github}` or `%Issue{tracker: :github}` clause. The GitHub-specific shaping goes in single-function utils next to the Linear ones, and the HTTP calls go in the existing `Rail.GitHub.Client`.
- GitHub issue `node_id` goes in `external_id`, so it is unique across both trackers and the unique index stays as it is. The REST number goes in `issues.number`. The identifier is `<key>#<number>` (for example `foo#123`). Rail builds the branch name, `foo-123-short-title`, once when the issue is created.
- State is mapped with labels (`rail: todo` and so on, every Rail label prefixed `rail:` so it cannot clash with a repo's own labels) plus open/closed and `state_reason`. Priority uses `rail: priority …` labels. GitHub has no estimate field, so estimates are not mapped.
- Inbound: polling comes first (it works on localhost and is needed anyway, because GitHub does not retry failed deliveries). GitHub App webhooks (`issues`, `issue_comment`) come next, verified with `X-Hub-Signature-256` against `GITHUB_WEBHOOK_SECRET`.
- Phase 1 is three small PRs that let a GitHub project run a task from capture to merged PR. Inbound sync, webhooks, UI polish, assets and triage follow.

---

## 1. Inventory of Linear touchpoints

88 non-test files under `lib/` and `config/` mention Linear. Many of those mentions are only comments or copy. Each file is marked with what happens to it:

- **KEEP**: correct as is, or it already goes through `Rail.Issues` and dispatches for free.
- **DISPATCH**: moves behind the tracker switch (it gets a GitHub clause or counterpart).
- **LINEAR-ONLY**: stays Linear-specific and is unused or hidden for GitHub projects.
- **COPY**: only user-facing text or a comment changes.

### 1.1 Linear client, OAuth, config
| File | What | Fate |
|---|---|---|
| `lib/rail/linear.ex`, `lib/rail/linear/client.ex` | GraphQL client, OAuth, workspace and user tokens | LINEAR-ONLY |
| `lib/rail_web/controllers/linear_auth_controller.ex`, `/auth/linear` routes | per-user Linear OAuth | LINEAR-ONLY |
| `config/runtime.exs` `:linear_oauth`, `config/test.exs` `:linear` stubs | config | LINEAR-ONLY |
| `lib/rail/tools/utils/env.ex` | removes `LINEAR_CLIENT_*` from agent env | KEEP, and add `GITHUB_WEBHOOK_SECRET` |
| `lib/rail/github/client.ex` | moduledoc compares itself to the Linear client | DISPATCH: add issue, comment and label endpoints (§3.1) |

### 1.2 Projects context
| File | What | Fate |
|---|---|---|
| `lib/rail/projects/schemas/project.ex` | requires `linear_team_key`; `put_linear_team_id` asks Linear for the team and state ids in `prepare_changes` | DISPATCH: requirements depend on the tracker; the Linear lookup only runs for `:linear` |
| `lib/rail/projects/schemas/linear_workspace.ex` | workspace token and webhook secret | LINEAR-ONLY |
| `lib/rail/projects/actions/{create,get,list,update}_linear_workspace.ex` | workspace CRUD | LINEAR-ONLY |
| `lib/rail/projects/actions/{create,get,list,update}_project.ex` | preload `:linear_workspace` | KEEP (a nil assoc is harmless). `get_project/1` gets a `by` keyword clause for the webhook lookup (§4.2) |
| `lib/rail/projects.ex` | delegates | KEEP, plus the new `get_project(by)` clause |

### 1.3 Issues context, outbound (Rail to tracker)
| File | What | Fate |
|---|---|---|
| `lib/rail/issues/actions/create_issue.ex` | creates in Linear synchronously, inserts the row from Linear's response; `linear_team_id: nil` returns `{:error, :linear_team_not_found}` | DISPATCH |
| `lib/rail/issues/schemas/issue.ex` | `changeset/2` enqueues `SyncIssue` (`sync_to_linear`); `linear_changeset/2` is the mirror write with no push | DISPATCH: add `tracker`, `number` and `external_updated_at`; rename to `sync_to_tracker` / `tracker_changeset` in the cleanup PR |
| `lib/rail/issues/workers/sync_issue.ex` | pushes changed fields to Linear | DISPATCH: GitHub clause |
| `lib/rail/issues/actions/comment.ex` | `commentCreate` as the user or the workspace | DISPATCH |
| `lib/rail/issues/actions/advance_issue_state.ex` + `workers/advance_linear_state.ex` | moves the state forward only, following the task stage | DISPATCH: new `workers/advance_github_state.ex`; the action picks the worker by `issue.tracker` |
| `lib/rail/issues/actions/claim_issue.ex` | requires `linear_user_id` | DISPATCH: a GitHub issue requires `github_id` |
| `lib/rail/issues/actions/upload_asset.ex`, `get_asset.ex` | Linear file upload and proxy | DISPATCH: `{:error, :unsupported}` for GitHub until PR 9 |
| `lib/rail/issues/utils/linear_priority.ex` | priority to Linear number | LINEAR-ONLY |
| `lib/rail/issues/actions/update_issue.ex`, `get_issue.ex`, `list_issues.ex` | local only | KEEP |
| `lib/rail/issues/schemas/comment.ex` | moduledoc says "mirrored from Linear" | COPY |
| `lib/rail/issues.ex` | moduledoc "Linear-backed issues" | COPY, plus new delegates (`handle_github_webhook/3`) |

### 1.4 Issues context, inbound (tracker to Rail)
| File | What | Fate |
|---|---|---|
| `lib/rail/issues/actions/handle_linear_webhook.ex` | Linear webhook | LINEAR-ONLY. GitHub gets `handle_github_webhook.ex` |
| `lib/rail/issues/workers/linear_sync.ex` | paged full pull | LINEAR-ONLY. GitHub gets `github_sync.ex` |
| `lib/rail/issues/actions/sync_issues.ex` | enqueues `LinearSync` | DISPATCH |
| `lib/rail/issues/actions/import_issue.ex` | imports one issue by identifier (used by triage) | DISPATCH |
| `lib/rail/issues/utils/format_linear_issue.ex`, `format_linear_comment.ex`, `upsert_linear_comment.ex` | payload to attrs | LINEAR-ONLY. GitHub counterparts in §3.8 |
| `lib/rail_web/controllers/linear_webhook_controller.ex`, `/webhooks/linear` | HMAC check, then `Issues.handle_linear_webhook/2` | LINEAR-ONLY. A GitHub controller sits next to it |

### 1.5 Users and Scope
| File | What | Fate |
|---|---|---|
| `lib/rail/users/schemas/user.ex` | `linear_*` fields; also has `github_id`, `login`, `github_token` from sign-in | KEEP. GitHub mapping uses `github_id` and `login` |
| `lib/rail/users/actions/{linear_token,link_linear,unlink_linear}.ex` | Linear account link | LINEAR-ONLY |
| `lib/rail/users/actions/list_linear_users.ex` | assignee menu (users with `linear_user_id`) | DISPATCH: rename to `list_assignable_users/1` with a `:tracker` filter (standards: one listing plus filters) |
| `lib/rail/scope.ex` | `linear_linked?/1` | LINEAR-ONLY (not used by the GitHub path) |

### 1.6 Pipeline
| File | What | Fate |
|---|---|---|
| `lib/rail/pipeline/actions/enter_stage.ex` | `@linear_stages` call `Issues.advance_issue_state/1` | KEEP (the call dispatches). Renaming to `@tracked_stages` is optional |
| `lib/rail/pipeline/actions/start_product_run.ex` | `Issues.advance_issue_state/1` | KEEP |
| `lib/rail/pipeline/actions/create_task.ex` | worktree name = `issue.branch_name` (falls back to the slugged identifier) | KEEP (GitHub issues get a Rail-built `branch_name`) |
| `lib/rail/pipeline/actions/approve_design.ex` | uploads the screenshot to Linear and appends it to the description; a failed upload fails the approval | DISPATCH: on `{:error, :unsupported}`, publish the section without the image (PR 3). Real hosting comes in PR 9 |
| `lib/rail/pipeline/utils/demo_run_finished.ex` | uploads the video and comments; failure is only logged | KEEP (logs "could not publish" until PR 9) |
| `lib/rail/pipeline/utils/open_pull_request.ex` | PR body starts with `issue.url` | DISPATCH: add `Closes #N` for GitHub issues (PR 3) |
| `lib/rail/pipeline/utils/commit_message.ex`, `approve_product_plan.ex`, `save_ticket.ex`, `read_ticket.ex` | use `identifier` in the trailer and file names | KEEP (`#` is a valid file-name character and these paths never pass through a shell) |
| `lib/rail/pipeline/schemas/run.ex`, `task.ex`, `create_task.ex` docs | comments | COPY |

### 1.7 Triage
| File | What | Fate |
|---|---|---|
| `lib/rail/triage/actions/triage_thread.ex` | prompt: "search Linear … on the `linear_team_key` team", "state in Linear" | DISPATCH: wording per tracker (PR 10) |
| `lib/rail/triage/actions/sync_triage.ex` | `Issues.import_issue/2` for `existing_issue` | KEEP (dispatches) |
| `lib/rail/triage/actions/create_triage_issue.ex` | `Issues.create_issue/3` | KEEP (dispatches); COPY on the docstring |
| `lib/rail/triage/schemas/item.ex`, `utils/slack_issue_link.ex` | copy; the link uses `issue.url` | KEEP |

### 1.8 Learnings
| File | What | Fate |
|---|---|---|
| `lib/rail/learnings/utils/apply_proposal.ex` | `Issues.create_issue/3` | KEEP (dispatches) |
| `lib/rail/learnings/actions/handle_issue_finished.ex`, `curate_learnings.ex` | comments | COPY |
| `lib/rail_web/live/learnings_live.ex` | error copy `linear_team_not_found` | COPY, plus GitHub error copy |

### 1.9 MCP
| File | What | Fate |
|---|---|---|
| `lib/rail/mcp/client.ex`, `schemas/mcp_server.ex`, `utils/tool_allowed.ex`, `settings/mcp_servers_live.ex` | `linear__get_issue` used only as an example | KEEP |

### 1.10 Web
| File | What | Fate |
|---|---|---|
| `lib/rail_web/router.ex` | `/webhooks/linear` | add `post "/github"` (PR 6) |
| `lib/rail_web/live/settings/projects_live.ex` | Linear Team Key and Linear Workspace inputs; list shows `linear_team_key` | DISPATCH: tracker choice and conditional fields (PR 1, polished in PR 7) |
| `lib/rail_web/live/settings/linear_workspaces_live.ex`, `components/settings_nav.ex` | Linear workspaces tab | LINEAR-ONLY |
| `lib/rail_web/live/settings/connected_accounts_live.ex`, `users_live.ex` | Linear connect and badge | LINEAR-ONLY (copy: "only needed for Linear projects") |
| `lib/rail_web/components/capture_issue_modal.ex` | `project_label` uses `linear_team_key` | DISPATCH: use `project.key` |
| `lib/rail_web/components/nav.ex`, `project_badge.ex` | show `linear_team_key` | DISPATCH: `project.key` |
| `lib/rail_web/live/issues_live.ex` | "Pulls issues from Linear", subtitle | COPY per tracker |
| `lib/rail_web/live/issue_live.ex`, `task_live.ex` | `Users.list_linear_users`, "Linear Issue" tab, claim error copy | DISPATCH (assignees) and COPY |
| `lib/rail_web/components/issue_view.ex`, `issue_card.ex` | "Open in Linear", `#issue-linear-link`, reply threads | COPY per tracker; hide replies for GitHub |
| `lib/rail_web/components/issue_icons.ex`, `overview_live.ex`, `triage_live.ex`, `learnings_channel_picker.ex` | copy and comments | COPY |
| `lib/rail_web/utils/handle_issue_event.ex` | comment only | COPY |
| `lib/rail_web/controllers/issue_asset_controller.ex` | proxies Linear uploads | KEEP (goes through `Issues.get_asset`, which dispatches) |
| `lib/rail_web/utils/render_markdown.ex` | rewrites `uploads.linear.app` to the proxy | DISPATCH in PR 9 (rewrite Rail's GitHub asset URLs too) |

### 1.11 Test infrastructure and seeds
| File | What | Fate |
|---|---|---|
| `lib/test_helper.exs` | seeds a Linear workspace and project into `:persistent_term {RailTest, :project}` | KEEP, and seed a second `{RailTest, :github_project}` |
| `test/support/data_case.ex` | `setup` returns `%{project: …}` | also return `github_project` |
| `test/support/triage_helpers.ex`, `learnings_helpers.ex` | `Req.Test.expect(Rail.Linear, …)` | KEEP |
| `priv/repo/seeds.exs` | Linear dev project | optionally add a GitHub dev project |
| `priv/repo/migrations/*` | history | untouched |

---

## 2. Design

### 2.1 Tracker switch: function clauses, not a behaviour
- Recommended: dispatch by pattern match on `%Project{tracker: …}` (create, sync) or `%Issue{tracker: …}` (update, comment, advance, claim, assets) inside the existing actions and workers.
  - This matches the repo: there are no behaviours today, actions have one public function, and utils have one public function (Credo `ActionModuleNaming`, plus the util rule).
  - With two trackers, a behaviour plus two 8-function adapter modules would be more ceremony than the clauses.
- Tracker-specific shaping goes in single-function utils: `FormatGithubIssue`, `FormatGithubComment`, `UpsertGithubComment`, `GithubIssueLabels`, `CalculateGithubState`.
- All GitHub HTTP goes in `Rail.GitHub.Client`. It stays a dumb client that returns what GitHub said.
- Revisit with `Rail.Issues.Tracker` callbacks if a third tracker (Jira, etc.) arrives.
- Issue-level operations dispatch on `issue.tracker`, not `project.tracker`. That way an issue keeps working with the tracker it came from even if the project's tracker setting is edited later. Switching is blocked anyway (§2.3).

### 2.2 Schema changes

**Project** (`lib/rail/projects/schemas/project.ex`)
- `field :tracker, Ecto.Enum, values: [:linear, :github], default: :linear`
- `field :key, :string`: the short project key used in identifiers and badges.
  - Required when `:github`. If blank, it defaults to the repo name (`acme/foo` gives `foo`).
  - Format: `validate_format(~r/^[a-z0-9][a-z0-9_-]*$/i)`, `validate_length(max: 20)`.
- Changeset:
  - `validate_required` = base fields, plus `[:linear_team_key]` when the tracker is `:linear`, plus `[:key]` when it is `:github`.
  - `put_linear_team_id/1` runs only when `get_field(changeset, :tracker) == :linear`.
  - `validate_change(:tracker, …)` refuses a change once the project has issues. This is a `prepare_changes` check, or a check in `UpdateProject`.
- Linear columns `linear_team_key`, `linear_team_id`, `linear_state_ids` and `linear_workspace_id` are **kept**. They are nullable and ignored for GitHub. Nothing is dropped, because Linear is still a first-class tracker.

**Issue** (`lib/rail/issues/schemas/issue.ex`)
- `field :tracker, Ecto.Enum, values: [:linear, :github], default: :linear`. This follows the standards rule that a table shared by several services carries a provider field. It is set from the project in `CreateIssue` and the inbound writers, and it is not castable from user attrs.
- `field :number, :integer`: the GitHub issue number, which REST paths need. Nil for Linear.
- `field :external_updated_at, :utc_datetime_usec`: the tracker's `updated_at`. It is the incremental poll cursor and the stale-webhook guard (§4.3).
- Required fields are unchanged (`external_id`, `identifier`, `title`, `state`). GitHub provides all of them.

**Comment**: no schema change. `external_id` = the GitHub comment `node_id` (`IC_…`).

### 2.3 Migrations (PR 1)
- `priv/repo/migrations/<ts>_add_tracker_to_projects_and_issues.exs`:
  ```elixir
  alter table(:projects) do
    add :tracker, :text, null: false, default: "linear"
    add :key, :citext
    modify :linear_team_key, :text, null: true, from: {:text, null: false}
  end

  create constraint(:projects, :linear_projects_have_team_key,
           check: "tracker <> 'linear' OR linear_team_key IS NOT NULL")

  alter table(:issues) do
    add :tracker, :text, null: false, default: "linear"
    add :number, :integer
    add :external_updated_at, :utc_datetime_usec
  end
  ```
  - `linear_team_key` is still `NOT NULL` in the DB today (only `linear_team_id` was relaxed in `20260913182213`).
  - The default `'linear'` backfills every existing row.
- `<ts>_index_projects_key.exs`: `create unique_index(:projects, [:key], where: "tracker = 'github'", concurrently: true)` with `@disable_ddl_transaction true` and `@disable_migration_lock true` (existing table). The index is partial so existing Linear projects need no backfill. If Linear projects also want `key` for the badge, backfill `key = linear_team_key` in PR 8.
- `<ts>_index_issues_external_updated_at.exs`: `create index(:issues, [:project_id, :external_updated_at], concurrently: true)` for the poll cursor.

### 2.4 `external_id` uniqueness across trackers
- Keep the existing global `unique_index(:issues, [:external_id])` and `unique_index(:issue_comments, [:external_id])`.
- Use GitHub's GraphQL **`node_id`** (`I_kwDO…` for issues, `IC_kwDO…` for comments), not the numeric `id` or the `number`:
  - It is globally unique and stable across repo renames and transfers.
  - It cannot collide with Linear UUIDs.
  - `LinearSync`'s `conflict_target: :external_id` and every `Repo.get_by(…, external_id:)` keep working untouched.
- A composite `(tracker, external_id)` index was considered and rejected: it changes every upsert's conflict target for no real gain.

### 2.5 Identifier and branch name
- Identifier: `"#{project.key}##{number}"`, for example `foo#123`. It reads like GitHub's own short reference.
  - `get_issue/2` already matches `identifier`. Uniqueness comes from the unique `key` among GitHub projects. Today a duplicate identifier would raise in `Repo.one`.
  - Routes: `~p"/issues/#{issue.identifier}"` percent-encodes `#` as `%23`, and Phoenix decodes the path param. PR 2 pins this with an `IssueLive` test.
  - File names: `tickets/foo#123.md`, `foo#123-demo.webm`. `#` is legal in POSIX file names and these paths are only touched by Rail and its MCP tools, never a shell. When used as a GitHub Contents API path (PR 9), encode it as `%23`.
  - Alternative: `FOO-123`. It needs zero downstream changes but looks like Linear and loses GitHub's `#` convention. It is listed as an open question.
- Branch name: GitHub does not provide one, so `FormatGithubIssue` builds `"#{key}-#{number}-#{slug(title)}"` (lowercase, `[^a-z0-9]+` becomes `-`, title part up to 40 chars, trimmed of `-`). Example: `foo-123-fix-login-redirect`, which mirrors Linear's `eng-301-…`.
  - It is set **only on insert**. Upserts never replace `branch_name`, so a title rewritten by the product stage does not rename the branch. `create_task` freezes `worktree_name` anyway.

---

## 3. GitHub implementation

### 3.1 `Rail.GitHub.Client` additions (`lib/rail/github/client.ex`)
Same shape as the existing PR functions: `token, repo, …, opts`, return `{:ok, body}` or `{:error, {:github_api_error, status, body}}`.
- `create_issue(token, repo, attrs)`: `POST /repos/{repo}/issues` (`title`, `body`, `labels`, `assignees`). Expects 201.
- `get_issue(token, repo, number)`: `GET /repos/{repo}/issues/{n}`.
- `update_issue(token, repo, number, attrs)`: `PATCH /repos/{repo}/issues/{n}` (`title`, `body`, `state`, `state_reason`). Never send `labels` or `assignees` here, because each replaces the whole list.
- `add_assignees(token, repo, number, logins)` / `remove_assignees(token, repo, number, logins)`: `POST` / `DELETE /repos/{repo}/issues/{n}/assignees`.
- `list_issues(token, repo, params)`: one page of `GET /repos/{repo}/issues` (`state=all&sort=updated&direction=asc&since=…&per_page=100&page=n`). **This also returns PRs**; callers drop items that have a `"pull_request"` key.
- `list_repo_issue_comments(token, repo, params)`: `GET /repos/{repo}/issues/comments?sort=updated&direction=asc&since=…`. This is every comment in the repo in one stream, PR conversation comments included.
- `create_issue_comment(token, repo, number, body)`: `POST /repos/{repo}/issues/{n}/comments`.
- `add_labels(token, repo, number, names)`: `POST /repos/{repo}/issues/{n}/labels`.
- `remove_label(token, repo, number, name)`: `DELETE /repos/{repo}/issues/{n}/labels/{name}`. A 404 counts as `:ok`.
- `create_label(token, repo, name, color, description)`: `POST /repos/{repo}/labels`. A 422 `already_exists` counts as `:ok`.
- Errors: a 403 "Resource not accessible by integration" becomes `{:error, :github_issues_permission_missing}` (the App was not granted Issues). A 410 becomes `{:error, :github_issues_disabled}`.
- Token: `installation_token(project.github_installation_id)` per job, as `OpenPullRequest` does. Later, cache it in `Rail.Cache` for about 50 minutes (each token mint is one extra request).

### 3.2 Create (`lib/rail/issues/actions/create_issue.ex`)
- New clause `create_issue(%Scope{}, %Project{tracker: :github} = project, attrs)`:
  1. `installation_token`, `GithubIssueLabels.github_issue_labels(:triage, priority)`, then `GitHub.create_issue(token, repo, %{title, body: description, labels: ["rail: triage", "rail: priority high"], assignees: [owner.login]})`.
  2. `format_github_issue(project, gh_issue)`, merged with `project_id`, `tracker: :github`, `owner_user_id`, `priority`, `state: :triage`. Then insert and broadcast `{:issue_created, id}` as today.
- **Race:** a webhook or poll can mirror the new issue before the insert. GitHub fires `issues.opened` the moment the REST call returns. Insert with `on_conflict: {:replace, [...]}, conflict_target: :external_id` (or `get_by` then `insert_or_update`) so the capture never fails on a row that already exists. The Linear clause has the same latent race and can adopt the same fix.
- Authorship: Phase 1 creates as the App (`rail-app[bot]`). PR 8 adds "as the scope's user via `user.github_token`, falling back to the App", mirroring `OpenPullRequest.create/3`.
- The Linear clause keeps `%Project{tracker: :linear, linear_team_id: nil}` returning `{:error, :linear_team_not_found}`.

### 3.3 Update push (`lib/rail/issues/workers/sync_issue.ex`)
- `push(%Issue{tracker: :github} = issue, fields)` maps `@pushable` as follows:
  - `title` and `description` go to `PATCH {title, body}`.
  - `owner_user_id`: `POST /repos/{repo}/issues/{n}/assignees {assignees: [new_owner.login]}` and `DELETE …/assignees {assignees: [previous_owner.login]}`. Only Rail's owner is added or removed; other assignees people set on GitHub stay (decided, §8). The previous owner comes from the changeset's old `owner_user_id`, which the job args must carry.
  - `state`:
    - Open states: add the target `rail:` status label and remove the other `rail:` status labels already on the issue. This needs one `get_issue` first. If the issue is closed, also `PATCH {state: "open"}`.
    - `:done`: `PATCH {state: "closed", state_reason: "completed"}`.
    - `:canceled`: `{state_reason: "not_planned"}`.
    - `:duplicate`: `{state_reason: "duplicate"}`, falling back to `not_planned` plus a `rail: duplicate` label (see §8).
  - `priority`: add the `rail: priority …` label and remove the other `rail: priority …` labels.
  - `estimate`: not pushed.
- It never PATCHes `labels` wholesale, so labels people add by hand survive. This keeps the existing rule that "Rail is one of two writers."

### 3.4 Comments (`lib/rail/issues/actions/comment.ex`)
- `%Issue{tracker: :github}` clause: `create_issue_comment(token, repo, issue.number, body)`, then `upsert_github_comment(issue, gh_comment)`.
- GitHub comments are flat. If `parent_id` is given, prefix the body with `> ` quoting the parent's first lines and store the comment top-level. PR 7 hides the "Leave a reply" form for GitHub issues.
- Author: PR 2 uses the App token. PR 8 uses the scope user's `github_token` with an App fallback.

### 3.5 State mapping: labels (recommended) vs. Projects v2

| Rail state | GitHub representation | Inbound rule |
|---|---|---|
| `triage` | open + `rail: triage` | |
| `backlog` | open + `rail: backlog` | open with **no** `rail:` status label also means backlog (decided: issues filed on GitHub count as accepted work) |
| `todo` | open + `rail: todo` | |
| `in_progress` | open + `rail: in progress` | |
| `in_review` | open + `rail: in review` | |
| `done` | closed, `state_reason: completed` (or null) | `completed_at` = `closed_at` |
| `canceled` | closed, `state_reason: not_planned` | |
| `duplicate` | closed, `state_reason: duplicate` | or `not_planned` + `rail: duplicate` label |

- Closed always wins over a leftover `rail:` status label. If an issue has several status labels, the most advanced one wins.
- `state_name` is `Issue.state_label(state)` (for example "In Progress"). Closed issues get "Done", "Canceled" or "Duplicate".
- Labels are created idempotently (`create_label`, 422 is ok) the first time a project uses them. This is a one-off job enqueued when a GitHub project is saved, and it does not rely on GitHub auto-creating labels.
- Priority: `rail: priority urgent|high|medium|low`. No label means `:medium` (Rail's default, the same as Linear's 0). Several labels: the highest wins.
- Estimate: not mapped (stays nil). A later option is an `estimate: N` label or a Projects v2 number field.
- **Labels vs. GitHub Projects v2:**
  - Labels:
    - The repo-scoped REST API is the one the App already uses.
    - Changes arrive on the `issues` webhook (`labeled`/`unlabeled`).
    - They are visible everywhere (lists, search `label:"rail: todo"`).
    - They need no new App permission beyond Issues.
    - Downsides: labels are free-form, so a human can apply two at once, and there is no board column ordering.
  - Projects v2:
    - A real single-select Status field and a board.
    - But it is GraphQL-only, and needs project, item and field-option node ids. That means a lookup like `linear_state_ids`.
    - It needs an org-level `Projects: read/write` permission.
    - `projects_v2_item` webhooks are org-level only and do not fire for user-owned projects.
    - Every issue must also be added to the project as an item.
  - **Recommendation: labels now.** Optionally mirror into a Projects v2 Status field later as a one-way push.

### 3.6 Forward-only advance (`lib/rail/issues/workers/advance_github_state.ex`)
- `AdvanceIssueState.advance_issue_state/1` enqueues `AdvanceLinearState` or `AdvanceGithubState` by `issue.tracker`. It uses the same `unique: [keys: [:issue_id], states: :incomplete, period: :infinity]` and the same "only once owned" rule.
- The target is `:in_progress` for product, design, architect and engineer, and `:in_review` for review, QA and demo.
- Get the live issue, compute its current Rail state with `CalculateGithubState`, rank it (triage 0, backlog 1, todo 2, in_progress 3, in_review 4, closed 5), and move the label only forward. The snooze-on-stage-change loop is copied from the Linear worker.

### 3.7 Owner and assignees
- Rail user to GitHub: `owner_user.login`. Every Rail user signs in with GitHub, so `login` and `github_id` are always present.
- GitHub to Rail: the first `assignees[]` whose `id` matches `users.github_id` (a string column, so compare `to_string(id)`). No match leaves the issue unowned, as Linear does today.
- `ClaimIssue`: the GitHub clause requires `user.github_id` instead of `linear_user_id`.
- `Users.list_assignable_users(tracker: :github, project_id: …)` returns users with `github_id`. The Linear variant keeps the `linear_user_id` filter.
- GitHub silently drops assignees without repo access. Surface nothing, matching Linear's behaviour for unknown users.

### 3.8 Inbound utils (Issues context)
- `utils/format_github_issue.ex`: `format_github_issue(project, gh)` returns `%{external_id: gh["node_id"], number, identifier, title, description: gh["body"], priority, state, state_name, branch_name, url: gh["html_url"], completed_at, external_updated_at: gh["updated_at"]}`. It uses `calculate_github_state/1` and the priority-from-labels mapping.
- `utils/calculate_github_state.ex`: `{state, state_name}` from `state`, `state_reason` and labels. It is shared by the formatter and `AdvanceGithubState`.
- `utils/github_issue_labels.ex`: the label names for a Rail state and priority, plus the full label catalogue with colors.
- `utils/format_github_comment.ex`: `%{external_id: node_id, body, author_name: user.login, author_avatar_url, inserted_at: created_at, updated_at, issue_number (parsed from issue_url), author_github_id}`.
- `utils/upsert_github_comment.ex`: mirrors `upsert_linear_comment.ex`. It resolves the issue by `(project_id, number)` and the author by `github_id`. Comments on PRs or unknown issues return `{:error, :issue_not_found}`, which is ignored.

---

## 4. Inbound sync

### 4.1 Polling first (build this first)
Why polling comes first:
- It works with Rail on `localhost`, where GitHub cannot reach a webhook.
- GitHub does **not** automatically redeliver failed webhooks, so a reconciling poll is needed in production anyway.
- It needs no App webhook configuration to start.

Pieces:
- `lib/rail/issues/workers/github_sync.ex` (queue `:issues`, `unique: [keys: [:project_id, :page], states: :incomplete]`):
  - Args: `project_id`, optional `since`, `page`.
  - `since` defaults to `max(issues.external_updated_at)` for the project, so the cursor needs no new state. A full sync (decided, §8) imports every open issue plus issues closed in the last 30 days: it pages `state=open`, then `state=closed&since=<now - 30 days>`, and skips closed items whose `closed_at` is older than that. Older closed issues are never imported.
  - Each page:
    1. `list_issues`, dropping PRs.
    2. Read the existing `{external_id, state}` rows first, so transitions can be detected.
    3. `insert_all` with `conflict_target: :external_id` and `on_conflict: {:replace, @replace_issue}`, where `@replace_issue` excludes `branch_name`.
    4. Call `Learnings.handle_issue_finished/1` for rows that went from active to finished. `LinearSync` does not do this, because Linear relies on its webhook. A poll-first GitHub sync has to.
    5. Queue the next page. On the last page, sync comments via `list_repo_issue_comments(since: max comment updated_at)`, then broadcast `{:issues_synced, project_id}`.
- `lib/rail/issues/workers/schedule_github_syncs.ex`: a cron entry `{"* * * * *", Rail.Issues.Workers.ScheduleGithubSyncs}` in `config/config.exs`.
  - It enqueues an incremental `GithubSync` per active GitHub project.
  - Cost is about 2 requests plus 1 token per project per minute, against a 5,000/hour installation budget.
- `SyncIssues.sync_issues/1` dispatches: Linear gets `LinearSync`, GitHub gets a full `GithubSync` (the "Sync" button).
- `ImportIssue.import_issue/2` GitHub clause: parse `key#123`, `#123` or `123`, then `get_issue(token, repo, n)` and upsert. Triage's `existing_issue` uses this.
- Known gap: polling cannot see deleted issues or comments. Webhooks cover those.

### 4.2 GitHub App webhooks (second)
- Route: `post "/github", GitHubWebhookController, :handle` in the existing `scope "/webhooks"` (`:api` pipeline).
- `lib/rail_web/controllers/github_webhook_controller.ex`:
  1. Verify `X-Hub-Signature-256` (`"sha256=" <> hex(hmac_sha256(secret, raw_body))`) with `Plug.Crypto.secure_compare`. `conn.assigns[:raw_body]` is already captured by `RailWeb.Plugs.CacheBodyReader` in `endpoint.ex`. A missing or unset secret returns 401, so unsigned payloads are never accepted.
  2. `ping` returns 200.
  3. Look the project up with `Projects.get_project(github_repo: payload["repository"]["full_name"])`. This is a new `by` keyword clause on `get_project`. Check `installation.id == project.github_installation_id` and `project.tracker == :github`. An unknown repo returns 200 with an `ignored` body, so GitHub does not mark the delivery as failed.
  4. `Issues.handle_github_webhook(project, event, payload)`, where `event` comes from `X-GitHub-Event`.
- `lib/rail/issues/actions/handle_github_webhook.ex` (mirrors `handle_linear_webhook.ex`):
  - `issues`:
    - `opened`, `edited`, `reopened`, `closed`, `labeled`, `unlabeled`, `assigned`, `unassigned`: upsert with `Issue.linear_changeset/2` (which becomes `tracker_changeset`), so nothing is pushed back. On a transition to finished, call `Learnings.handle_issue_finished/1`. Broadcast `{:issue_changed, id}`.
    - `deleted` and `transferred`: delete the row.
  - `issue_comment`: `created` and `edited` go through `upsert_github_comment`; `deleted` deletes the comment and broadcasts `{:issue_comments_changed, issue_id}`. Skip payloads where `issue.pull_request` is present.
  - Anything else: `:ok`.

### 4.3 Ordering and echo
- Echo: Rail's own writes come back as webhooks. They are idempotent upserts through the no-push changeset, so there is no loop.
- Stale events: deliveries are not ordered. Skip an issue payload whose `issue.updated_at < issues.external_updated_at`. Compare the same way for comments using `updated_at`.

---

## 5. GitHub App and environment

### 5.1 App settings (GitHub, done by an admin)
- Repository permissions:
  - **Issues: Read and write** (new).
  - Contents: Read and write (existing; also used by PR 9 assets).
  - Pull requests: Read and write (existing).
  - Metadata: Read (existing).
- Webhook:
  - Active.
  - URL `https://<PHX_HOST>/webhooks/github`.
  - Content type `application/json`.
  - Secret = `GITHUB_WEBHOOK_SECRET`.
- Subscribe to events: **Issues** and **Issue comment**. **Pull request** is optional and later; it could replace PR polling and drive learnings.
- Every existing installation (org owner) must **accept the updated permissions**. Until they do, issue calls return 403, which Rail maps to `:github_issues_permission_missing` and shows in the UI.
- The repo must have Issues enabled. Optionally check `GET /repos/{repo}` `has_issues` when a GitHub project is saved (PR 8).

### 5.2 New configuration
- `GITHUB_WEBHOOK_SECRET` goes to `config :rail, :github, webhook_secret: get_env.("GITHUB_WEBHOOK_SECRET", "github_webhook_secret")` in `config/runtime.exs`. Also add it to `@app_vars` in `lib/rail/tools/utils/env.ex` so agents never see it.
- No other env vars are needed. Polling is always on (it is cheap and reconciles). If a kill switch is wanted, use `RAIL_GITHUB_ISSUE_POLL=0`; it is removed from agent env automatically by the `RAIL_` prefix rule.
- Local dev webhooks are optional: smee.io (`npx smee -u <channel> -t http://localhost:4000/webhooks/github`) works for App webhooks.

---

## 6. UI changes

- **Project settings** (`lib/rail_web/live/settings/projects_live.ex`):
  - A "Issue tracker" radio (Linear / GitHub Issues), bound to `project[tracker]`.
  - GitHub shows a `Key` input with placeholder = the repo name, plus a one-line note on the App permissions and webhook URL.
  - Linear shows the current Linear Team Key and Linear Workspace fields.
  - Encode the variant as assigns (`show_linear_fields`, `show_github_fields`), not `case` in HEEx (standards).
  - The list row shows `project.key || project.linear_team_key` with a small tracker label.
  - The tracker radio is disabled once the project has issues.
- **Capture issue modal** (`components/capture_issue_modal.ex`): `project_label/1` uses the key. The `error_message/1` copy covers `:linear_team_not_found`, `:github_issues_permission_missing` and `:github_issues_disabled`.
- **Issues list** (`live/issues_live.ex`):
  - Subtitle "Issues in foo (GitHub)" or "Issues in ENG (Linear)"; "Issues across all projects" for all.
  - The Sync button title is "Pulls issues from the tracker".
  - `issue_card.ex` external link title is "Open issue in GitHub" or "Open issue in Linear".
- **Issue page** (`components/issue_view.ex`, `live/issue_live.ex`):
  - "Open in GitHub" / "Open in Linear". Rename the id to `issue-tracker-link` and update tests.
  - Hide reply forms when `issue.tracker == :github` (an assign `show_replies`).
  - Assignees come from `Users.list_assignable_users(tracker: issue.tracker, project_id: …)`.
- **Task page** (`live/task_live.ex`):
  - The tab label "Linear Issue" becomes "Issue".
  - The claim error is per tracker: `:linear_not_linked` keeps its text. GitHub has no link prompt, because every user has `github_id`.
- **Nav and badge** (`components/nav.ex`, `project_badge.ex`): show the key.
- **"Link Linear" prompts:**
  - Connected Accounts Linear card: add "Only needed for projects that use Linear."
  - Users list Linear badge: keep.
  - Settings tab "Linear Workspaces": keep (admin-only, harmless).
- **Copy-only:** `triage_live.ex` ("Nothing reaches Slack or the issue tracker until you accept it"), `learnings_live.ex` error map, `issue_icons.ex` and `overview_live.ex` comments.

---

## 7. Phased delivery (small, independently mergeable PRs)

Each PR passes `mix credo --strict`, compiles with `--warnings-as-errors`, keeps 100% coverage, and tests go through the context's public API with `Req.Test.expect(Rail.GitHub.Client, fn conn -> case {conn.method, conn.request_path} do … end end)`, the same pattern as `commit_engineer_work_test.exs`.

### Phase 1: a GitHub project runs a task end to end (outbound only)

**PR 1: Project tracker and optional Linear fields**
- Changes:
  - Both migrations (§2.3), plus the issue `tracker`, `number` and `external_updated_at` columns.
  - `Project` changeset (tracker, key, conditional requirements, the Linear lookup only for Linear, tracker locked once there are issues).
  - `Issue` gets the `tracker`, `number` and `external_updated_at` fields.
  - `projects_live.ex` gets the tracker radio and conditional fields.
  - Seed `{RailTest, :github_project}` in `lib/test_helper.exs` (`tracker: :github`, `key: "tgh"`, `github_repo: "example/test-gh"`, `github_installation_id: 1`).
  - `data_case.ex` exposes `github_project`.
- Tests:
  - `project_test.exs`: a GitHub project is valid with no Linear fields; it defaults `key` from the repo; it rejects a bad key; Linear still requires `linear_team_key`. Saving a GitHub project makes **no** Linear call: no `Req.Test.expect(Rail.Linear)` is set, and the default adapter raises on any unmocked call.
  - `update_project_test.exs`: refuses a tracker change once the project has issues.
  - `projects_live_test.exs`: choosing GitHub hides the Linear inputs and saves.
  - DB: inserting a Linear project with a nil team key hits the check constraint.

**PR 2: Create, push, comment and claim for GitHub issues**
- Changes:
  - `Rail.GitHub.Client` issue, comment and label functions (§3.1).
  - Utils `format_github_issue`, `calculate_github_state`, `github_issue_labels`, `format_github_comment`, `upsert_github_comment`.
  - GitHub clauses in `CreateIssue` (with the upsert race fix), `SyncIssue` (title, body, assignees, open/closed state), `Comment`, `ClaimIssue`, and `UploadAsset`/`GetAsset` (`{:error, :unsupported}`).
  - `Users.list_assignable_users/1` (rename of `list_linear_users`, with a `:tracker` filter).
  - `test/support/github_helpers.ex` with `github_issue_json(overrides)` and `github_comment_json(overrides)`, delegated from `RailTest.Helpers`. They are shared across 4+ test files, so this is allowed by `docs/tests.md`.
- Tests:
  - `client_test.exs` covers each new endpoint, including the 403 and 410 mapping.
  - `create_issue_test.exs` (GitHub cases): asserts the POST body (`title`, `body`, `labels: ["rail: triage", "rail: priority high"]`) and the row (`external_id: "I_kw…"`, `number: 42`, `identifier: "tgh#42"`, `branch_name: "tgh-42-short-title"`, `tracker: :github`). A second test covers "row already mirrored" returning `{:ok, issue}`.
  - `sync_issue_test.exs` (`use Oban.Testing`): `perform_job` sends only changed fields, never `labels` in the PATCH, and only the owner's login added or removed through the assignees endpoints, never an `assignees` key in the PATCH.
  - `comment_test.exs`: a reply posts a quoted top-level comment.
  - `claim_issue_test.exs`: a GitHub issue is claimable by a user with `github_id` and no Linear link.
  - `issue_live_test.exs`: `~p"/issues/#{"tgh#42"}"` mounts the issue.

**PR 3: State labels, forward advance, PR closes the issue**
- Changes:
  - `AdvanceGithubState` worker, plus dispatch in `AdvanceIssueState`.
  - `SyncIssue` state and priority label add/remove.
  - A label bootstrap job (`Issues.Workers.EnsureGithubLabels`) enqueued from `CreateProject`/`UpdateProject` when the tracker is GitHub. Projects can only reach Issues through `Rail.Issues`, so add an `Issues.ensure_labels(project)` delegate.
  - `OpenPullRequest.body/1` adds `Closes #<number>` for GitHub issues (it only works when the PR targets the default branch, which Rail's does).
  - `approve_design.ex` publishes the design section without an image on `{:error, :unsupported}`.
- Tests:
  - `advance_github_state_test.exs`: in_progress to in_review adds and removes the right labels; never moves backwards (the live issue already has "in review"); no-op while unowned; snoozes when the stage moved.
  - `enter_stage_test.exs`: the GitHub task enqueues `AdvanceGithubState`.
  - `open_pull_request` via `commit_engineer_work_test.exs`: the body contains `Closes #42`.
  - `approve_design_test.exs`: a GitHub issue approves and appends the text section.
- **End-to-end check (manual, documented in the PR):**
  1. Create a GitHub project against a scratch repo.
  2. Capture an issue and see it on GitHub in `rail: triage`.
  3. Start product, approve, then design, architect and engineer. The draft PR opens with `Closes #N`.
  4. Review and QA move the label to `rail: in review`. Demo runs, and logs that the video is not published (PR 9).
  5. Merge the PR and the issue closes on GitHub.
- Rail sees the issue close after Phase 2.

### Phase 2: inbound sync by polling
**PR 4: `GithubSync` (issues) and `ImportIssue`**
- Changes: `github_sync.ex` (paged, `since` cursor, drops PRs, branch_name kept, finished transitions go to Learnings), `SyncIssues` dispatch, `ImportIssue` GitHub clause.
- Tests:
  - A page with a PR item and an issue stores only the issue.
  - A second page is enqueued when there are 100 items.
  - The last page broadcasts `{:issues_synced, id}`.
  - Closing an active issue calls `Learnings.handle_issue_finished`. Use the Mimic copy of `Rail.Learnings` if it is already registered in `lib/test_helper.exs`; otherwise assert the enqueued job.
  - `branch_name` is unchanged after a title edit.
  - `import_issue(project, "tgh#7")` fetches `/issues/7`.
  - `sync_triage_test.exs` covers a GitHub project's `existing_issue`.

**PR 5: comment polling and cron**
- Changes: the comment pass in `GithubSync`, the `ScheduleGithubSyncs` cron worker, and the `config/config.exs` crontab entry.
- Tests:
  - Comments on unknown issues or PRs are skipped.
  - The author is mapped by `github_id`.
  - The scheduler enqueues one job per active GitHub project and none for Linear projects.
  - `issues_live_test.exs`: Sync on a GitHub project enqueues `GithubSync`.

### Phase 3: webhooks
**PR 6: `/webhooks/github`**
- Changes: the controller, the route, `Issues.handle_github_webhook/3`, the `get_project(by)` clause, `GITHUB_WEBHOOK_SECRET` in `runtime.exs` and `env.ex`, and the stale-event guard.
- Tests:
  - `github_webhook_controller_test.exs`, mirroring `linear_webhook_controller_test.exs` (sign `Jason.encode!(payload)` with the test secret, then `post ~p"/webhooks/github"` with the `x-github-event` and `x-hub-signature-256` headers):
    - 401 for a bad or missing signature.
    - 200 for `ping`.
    - Unknown repo ignored.
    - An installation mismatch is ignored.
  - `handle_github_webhook_test.exs`:
    - `opened` inserts.
    - `labeled` moves the state.
    - `closed` with `not_planned` gives `:canceled` and calls Learnings.
    - `deleted` removes the row.
    - Comment create, edit and delete.
    - A PR comment is ignored.
    - A stale `updated_at` is ignored.
    - A write does **not** enqueue `SyncIssue` (`refute_enqueued`).

### Phase 4: UI and attribution polish
**PR 7: tracker-aware UI**
- Changes: the §6 items not done in PR 1. Key in the nav, badge and capture modal; tracker link copy; hidden replies for GitHub; issues list subtitle; task tab label; claim and error copy; Connected Accounts note.
- Tests: update the existing LiveView tests that assert "Linear" copy or `#issue-linear-link`, and add GitHub variants: an issue page with no reply form, and a capture modal label showing the key.

**PR 8: act as the user, project checks**
- Changes:
  - Create and comment use the scope user's `github_token` with an App fallback (the `OpenPullRequest` pattern).
  - Check `has_issues` and permissions when a GitHub project is saved.
  - Optionally backfill `key = linear_team_key` for Linear projects so badges read only `key`.
- Tests:
  - The user token is used when present.
  - The App is used when there is no token or GitHub returns 401/403.
  - The project save shows the error "Issues are disabled on this repository".

### Phase 5: assets, triage, cleanup
**PR 9: assets for GitHub issues**
- Problem: GitHub has no API to upload issue attachments.
- Changes:
  - `UploadAsset` for GitHub writes via the Contents API (`PUT /repos/{repo}/contents/.rail-assets/<issue>/<file>`) on a dedicated `rail-assets` branch. The branch is created from the default branch on first use. Encode `#` in the path.
  - The returned URL is `https://github.com/{repo}/blob/rail-assets/<path>?raw=true`.
  - `GetAsset` fetches it with the installation token (`Accept: application/vnd.github.raw`).
  - `render_markdown.ex` rewrites those URLs to `/issues/:id/assets/…`.
  - Demo videos up to 100 MB fit the Contents/Blob limit.
- Tests:
  - Upload PUTs base64 content to the right path.
  - The design approval image is in the description.
  - The demo comment links the video.
  - The proxy serves the bytes.
  - Markdown rewrite.

**PR 10: triage on GitHub projects**
- Changes:
  - `triage_thread.ex` prompt per tracker: "search GitHub issues in `owner/repo`, open and closed, with the GitHub tools you were offered". `existing_issue` takes the form `key#123`.
  - Agents need a search tool. Recommend registering the GitHub MCP server in Settings > MCP servers and granting the triage role `github__search_issues` and `github__get_issue`. No code beyond the prompt.
- Tests: `triage_thread_test.exs` asserts the GitHub wording and no Linear team key in the brief for a GitHub project.

**PR 11: naming cleanup (no behaviour change)**
- Changes:
  - `Issue.linear_changeset` becomes `tracker_changeset`, and `sync_to_linear` becomes `sync_to_tracker`.
  - `@linear_stages` becomes `@tracked_stages`.
  - Moduledocs and comments that say "Linear" where they mean "the tracker" (`issues.ex`, `comment.ex`, `create_task.ex`, `run.ex`, `handle_issue_finished.ex`, `issue_view.ex`, `issue_live.ex`, `issue_icons.ex`).
  - Keep the Oban worker module names (`SyncIssue`, `AdvanceLinearState`, `LinearSync`), so in-flight jobs survive a deploy.
- Tests: the existing suite, unchanged.

---

## 8. Risks and open questions

**Decisions (made 2026-10-06)**
1. **Identifier format**: `foo#123`. A project's `key` cannot change once it has issues, so identifiers and branch names never go stale.
2. **Label names**: every Rail label carries a `rail:` prefix: `rail: triage`, `rail: in progress`, `rail: priority high`, and so on.
3. **An open issue with no Rail status label**: **backlog**, not triage. Issues filed on GitHub count as accepted work.
4. **Import scope**: every open issue, plus issues closed in the last 30 days, so Learnings sees recent finishes. Older closed issues are not imported.
5. **Assignees**: Rail adds and removes only its own owner; other assignees stay.
6. **Authorship**: the App bot (`<app-slug>[bot]`) in Phase 1, then the user's OAuth token in PR 8, falling back to the App when the org blocks user tokens.
7. **Switching tracker**: blocked once a project has issues. To switch, make a new project.
8. **Assets**: a `rail-assets` branch in the product repo.

**Risks**
- **App permission re-approval**: org owners must accept "Issues: read/write". Until then, GitHub projects fail on create with a clear error.
- **Lost webhooks**: GitHub does not redeliver automatically. The 1-minute incremental poll reconciles changes, but polling cannot see deletions.
- **Out-of-order deliveries**: guarded by `external_updated_at`. Missing the guard would let an old event overwrite a newer one.
- **Repo rename or transfer**: webhook lookup is by `repository.full_name`, which changes on rename (GitHub redirects the API, but `github_repo` goes stale). Consider storing `github_repo_id` later.
- **`state_reason: "duplicate"`**: newer API surface. Verify it on the target GitHub plan, otherwise fall back to `not_planned` + `rail: duplicate`.
- **Closing on merge**: `Closes #N` only acts when merging into the default branch. A task whose PR targets another base will not auto-close.
- **No estimates, no threaded replies** on GitHub. The UI hides replies, and estimates stay nil.
- **Label drift**: humans can add two `rail:` status labels or delete Rail's labels. Inbound picks the most advanced label, outbound recreates labels on demand.
- **Rate limits**: one token mint per job, plus polling. This is fine at Rail's scale; cache installation tokens if it becomes noisy.
- **Images in private-repo issue bodies**: `github.com/user-attachments/…` URLs in human-written issues may not load in Rail's issue page (they need a GitHub session). Verify, and decide whether to proxy them in PR 9.
- **Triage quality**: without a GitHub search tool the agent cannot find existing issues. PR 10 depends on the GitHub MCP server being registered.
