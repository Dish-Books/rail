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

**Linear connection**:
Users link their Linear account via OAuth (`actor=user`) so that actions attributable
to a human (e.g. issues, comments, branch sync) carry their identity. Tokens are stored
encrypted with Cloak.

**Linear token refresh**:
Calls to `linear_token/1` verify whether the access token expires within 5 minutes
(`<= 300 seconds`). If so, the action automatically refreshes tokens against Linear,
persists the new credentials, and returns the fresh access token.

**Linear unlinking**:
Users can disconnect their Linear account, which clears all stored tokens, user ID,
and display name.

## Relationships

- **Users → Linear**: Users can link their Linear identity. A Linear workspace token covers automated operations and unlinked users.
- **Users → Projects**: Global users have access to all projects, but admin-only operations (creating projects, editing roles, configuring linear workspaces) require `can?(scope, :manage_projects)` or admin status.
- **Users → Scope**: `Rail.Scope` wraps the current user (`%Scope{user: user}`) and derives admin status via `Scope.admin?(scope)`.
- **Users → UserTokens**: A user has many session tokens. Deleting a user cascades to deleting all their tokens.
