# Roles

Owns roles (pipeline stage bindings, system prompts, models, CLI backends, concurrency limits), role import/export/copy, run history digests, and the AI-driven role improvement flow.

## Language

**Role**:
An agent persona configured for a project. Each role defines its name, description, icon,
CLI backend (`:claude` or `:agy`), model name, optional reasoning effort (`:low`, `:medium`, `:high`),
system prompt, maximum concurrency limit, and ordering position.

**Stage Binding**:
A role can optionally be bound to a pipeline stage (`Rail.Domain.Enums.TaskStage`).
Within a single project, at most one role can be bound to any given stage (enforced by a partial unique index).
Roles with `stage: nil` are unbound roles available for ad-hoc or special assignments.

**Run History Digest**:
Extracts evidence from recent finished or failed runs of a role (`recent_finished_runs/3`),
producing structured `RoleRunRecord` entries with head/tail truncated transcripts.

**Role Improvement Flow**:
Analyzes a role's recent execution transcripts using a read-only agent runner guided by a meta-prompt,
proposing revised system instructions with a unified diff and explanatory rationale.

## Relationships

- **Roles → Projects**: Every role belongs to a `Project` via `project_id`.
- **Roles → Tasks & Pipeline**: Tasks execute pipeline stages with the role bound to that stage.
- **Roles → Runs**: Historical `role_runs` provide empirical evidence for the Improve flow.
- **Roles → Scope**: Managing roles requires admin scope (`Scope.admin?(scope)` or `can?(scope, :manage_roles)`), while all authenticated users can list and view roles.
