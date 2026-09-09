# Context Map

Rail is a coordinator for a fleet of CLI coding agents (`claude`, `agy`). Each top-level directory under `lib/rail/` is a Phoenix-style context with its own public API module (e.g. `Rail.Pipeline`, `Rail.Projects`, `Rail.Roles`). Contexts call each other only through those public modules, never into action modules or schemas directly.

## Contexts

- **Users** (`lib/rail/users/`) - GitHub OAuth login, Linear OAuth link/unlink/refresh, User and UserToken schemas, admin flag, and active project filter.
- **Projects** (`lib/rail/projects/`) - Projects (repo, GitHub installation id, default branch, clone path) and Linear workspaces (token, webhook secret).
- **Roles** (`lib/rail/roles/`) - Roles configured per project (stage binding, name, description, backend, model, effort, system prompt, concurrency), import/export/copy, improve flow, and run-history digest.
- **Issues** (`lib/rail/issues/`) - Linear issue mirror (sync, capture, webhook, ticket push, splits, comments, and uploads).
- **Pipeline** (`lib/rail/pipeline/`) - Task, stage machine, budgets, gates, questions, plans, chat, attention queue, merge/rebase decisions, briefs, and scratch materialization.
- **Runs** (`lib/rail/runs/`) - CLI child process management (argv/prompt, stream parsing, follower, boot adoption, RunFailure, usage).
- **Git** (`lib/rail/git/`) - Clones, worktrees, diffs, numstat, untracked synthesis, fingerprints, and diff models.
- **GitHub** (`lib/rail/github/`) - GitHub App installation tokens, PR state, merge, ready, branch delete, and PR lookups.
- **Artifacts** (`lib/rail/artifacts/`) - Demo, Design, and QA report manifests, Linear asset storage, validators, staleness, and scratch read/write.
- **Backends** (`lib/rail/backends/`) - CLI account usage probes and model registry.

## Relationships

- **Projects → everything**: all task, issue, role, and artifact data belongs to a Project. Actions take `scope`, then a `%Project{}` or a project-owned struct. Queries always filter by `project_id`.
- **Scope without tenancy**: `Rail.Scope{user, system}`. The `users.admin` boolean gates global admin settings (Projects, Users, Roles, Linear workspaces); all users can work within any active project.
- **Pipeline → Runs, Git, GitHub, Issues, Artifacts, Roles, Users**: Pipeline coordinates execution by calling other contexts strictly through their public top-level modules.
- **Postgres as source of truth**: ephemeral scratch files live in `$AXIS_SCRATCH/<task_id>` outside git worktrees and are captured into Postgres / Linear at stage settle.
