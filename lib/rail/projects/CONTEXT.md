# Projects

Owns projects (repositories, installations, branches, Linear teams, clone paths) and the singleton Linear workspace settings.

## Language

**Project**:
A managed codebase configured with its repository (`github_repo`), GitHub App installation ID,
default branch, local clone path, Linear team ID and key, cached Linear state IDs, and active status.
Every view in the application can display items across all active projects, with a project filter
narrows the scope.

**Linear Workspace**:
The global singleton workspace configuration (`linear_workspaces`) for the instance, storing the
workspace name, external ID, encrypted Linear API token, and encrypted webhook secret. Used for
system-level operations, sync jobs, asset proxying, and unlinked user write operations.

**Project Administration**:
Creating and updating projects as well as configuring the Linear workspace are restricted to
admin users (`Scope.admin?(scope)` or `can?(scope, :create_project)` / `can?(scope, :manage_projects)`).
All authenticated users can list and view projects.

## Relationships

- **Projects → LinearWorkspace**: A project optionally references `linear_workspace_id` (`belongs_to :linear_workspace`).
- **Projects → Tasks & Issues**: Tasks, issues, and roles all belong to a project and carry `project_id`.
- **Projects → Users**: Users can view all active projects, but only admins can create and update projects or edit workspace credentials.
- **Projects → Scope**: Actions require a caller `Scope` to enforce authorization boundaries.
