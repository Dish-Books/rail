# Users

Owns authentication, user sessions, authorization gates, and per-user preferences.
Users authenticate via GitHub OAuth; the first registered user is automatically
granted admin status.

## Language

**User**:
An authenticated human with a GitHub identity, stored with their display name,
email, login handle, avatar URL, and encrypted GitHub access token.

**Admin**:
A user with `admin: true`. Admins can manage global settings: Projects, Users,
Roles, and Linear workspaces. Non-admin users can view and work within any project.

**First user bootstrap**:
When the users table is empty, the first user to authenticate via GitHub OAuth
is automatically granted admin privileges (`admin: true`). Subsequent users
default to `admin: false`.

**Sole admin invariant**:
An admin cannot remove their own admin privileges if they are the only admin
in the system.

**User token**:
A cryptographically secure session token stored in `users_tokens`, valid for 14
days. Session tokens can be explicitly invalidated on logout.

**Project filter**:
The ID of the last project selected by the user, stored in `last_project_filter`.

## Relationships

- **Users → Projects**: Global users have access to all projects, but admin-only operations (creating projects, editing roles, configuring linear workspaces) require `can?(scope, :manage_projects)` or admin status.
- **Users → Scope**: `Rail.Scope` wraps the current user (`%Scope{user: user}`) and derives admin status via `Scope.admin?(scope)`.
- **Users → UserTokens**: A user has many session tokens. Deleting a user cascades to deleting all their tokens.
