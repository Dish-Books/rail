# Org and repository setup

What a GitHub org, and each repository in it, needs before Rail can work on it. The machine itself is covered in `docs/machine-setup.md`. Like that file, every step here has a check an LLM agent can run and report on.

## 1. The GitHub App

Rail reaches repositories as a GitHub App, never as a person: it clones, fetches, pushes, opens pull requests and, for GitHub-tracked projects, reads and writes issues with a short-lived installation token.

Create it in the org: Settings > Developer settings > GitHub Apps > New GitHub App.

- Homepage URL: Rail's URL (`http://localhost:4000` on a laptop).
- Callback URL and Setup URL: leave empty.
- Webhook: Active, URL `https://<rail-host>/webhooks/github`, and a secret you generate (`openssl rand -hex 32`), which also goes in Rail's `GITHUB_WEBHOOK_SECRET`. Rail refuses every delivery while that variable is unset.
- Repository permissions:

  | Permission | Access | Why |
  |---|---|---|
  | Contents | Read and write | clone, push, compare commits |
  | Pull requests | Read and write | open, update, mark ready, read reviews |
  | Issues | Read and write | GitHub-tracked projects: issues, comments, `rail:` labels |
  | Workflows | Read and write | only if agents may edit `.github/workflows`; GitHub refuses those pushes without it |
  | Metadata | Read | set by GitHub |

- Subscribe to events: **Issues** and **Issue comment**.
- Where can it be installed: only this account.

Then on the App's page:

- Note the **App ID** (a number, not the client id). It goes in `GITHUB_APP_ID`.
- Generate a private key. It goes in `GITHUB_APP_PRIVATE_KEY` as a path to the `.pem`.
- Install App, on the org, for all repositories or the ones Rail should work on. The installation page's URL ends in the **installation id**: `github.com/organizations/<org>/settings/installations/<id>`.

**Changing permissions later.** A permission added to the App does not reach an installation until an org owner accepts it: the installation page shows a banner to review and accept the request. Until then the tokens lack it, and Rail says so (for issues: "The GitHub App needs Issues: read and write on this repository").

Check, with the App's id and key: mint a JWT, then `POST /app/installations/<id>/access_tokens`. The `permissions` in the response include `contents: write`, `pull_requests: write` and, for GitHub-tracked projects, `issues: write`. A token from the same response can `GET /repos/<org>/<repo>` for each repository Rail should reach.

## 2. Signing in with GitHub (optional)

Only needed if people sign in with GitHub rather than `/dev/login`. Create an OAuth App (Settings > Developer settings > OAuth Apps) with callback `https://<rail-host>/auth/github/callback`, and put its credentials in `GITHUB_CLIENT_ID` and `GITHUB_CLIENT_SECRET`. This is separate from the GitHub App above.

## 3. Choosing an issue tracker

Each project picks one, and keeps it once it has issues.

- **GitHub Issues.** Nothing to set up beyond the App's Issues permission and webhook. Saving the project creates nine `rail:` labels in the repository (states and priorities). The Issues page's Sync button pulls every open issue and those closed in the last 30 days; after that, the App's webhook brings each change as it happens. An open issue with no `rail:` label counts as Backlog. Issues are named `<key>#<number>`, such as `foo#267`, and a pull request Rail opens closes its issue on merge (`Closes #N`).
- **Linear.** Add the workspace in Settings > Linear Workspaces, then give the project its team key.

## 4. Preparing each repository

Rail runs every task in its own git worktree, several at once. Anything a worktree starts (a dev server, tests) must not collide with another worktree's.

**Isolate ports and databases.** Every process Rail starts in a worktree (the setup script, CI, the agents) gets `RAIL_WORKTREE_SLOT` and `RAIL_PORT_BASE`. Read them in the dev and test config. For a Phoenix app:

```elixir
# config/dev.exs
rail_db_suffix = if slot = System.get_env("RAIL_WORKTREE_SLOT"), do: "_rail#{slot}", else: ""
# database: "myapp_dev#{rail_db_suffix}"
port = String.to_integer(System.get_env("PORT") || System.get_env("RAIL_PORT_BASE") || "4000")

# config/test.exs: the same suffix on myapp_test, and port RAIL_PORT_BASE + 2
```

Outside Rail neither variable is set, so nothing changes for people.

**A setup script.** It runs once in each new worktree, from its root, before any agent starts. It should leave a worktree that can compile, test and serve: fetch dependencies, install assets, create and migrate the databases. Copying `deps`, `_build` and `node_modules` from the primary checkout (`cp -a --reflink=auto`) makes the first compile incremental. Commit it executable (`chmod +x`); Rail runs it as `./<path>`.

**A CI command.** What Rail runs on every commit the engineer finishes, before it is pushed, for example `mix test`.

**Prompts (optional).** A stage runs `.rail/prompts/<stage>.md` from the repository's default branch when it exists, and the role's own prompt otherwise.

These have to be on the default branch: Rail cuts every worktree from it.

Check, in a scratch worktree with `RAIL_WORKTREE_SLOT=999 RAIL_PORT_BASE=29900` exported: the setup script exits 0, the CI command passes, and the databases it used carry the `_rail999` suffix. Then remove the worktree and drop those databases.

## 5. The clone Rail works from

Give Rail a clone of its own; never point it at a checkout someone works in. Rail detaches that checkout's HEAD and force-moves its default branch to `origin`'s on every fetch, and adds every worktree from its `.git`.

`origin` decides how Rail authenticates:

- **HTTPS** (`https://github.com/<org>/<repo>.git`): Rail pushes with the App's token. Works anywhere, including sandboxes and servers.
- **SSH** (`git@github.com:...` or a host alias from `~/.ssh/config`): git ignores the token and pushes with the SSH key of whoever runs Rail. Works only on that machine, and a passphrase-protected key needs `ssh-agent` running, because Rail runs git with no terminal.

Check: `git -C <clone> remote get-url origin` is the URL you meant, and `GIT_TERMINAL_PROMPT=0 git -C <clone> fetch origin` succeeds.

## 6. Registering the project

Settings > Projects > New Project:

| Field | Value |
|---|---|
| Project Name | anything |
| GitHub Repository | `<org>/<repo>` |
| Installation ID | from step 1 |
| Default Branch | usually `main` |
| Issue Tracker | GitHub Issues or Linear |
| Key | GitHub Issues: names its issues (`key#123`), defaults to the repo's name, fixed once there are issues |
| Linear Team Key, Linear Workspace | Linear only |
| Clone Path | the clone from step 5 |
| Worktree Setup Script | the script from step 4, relative to the repo root |
| CI command | from step 4 |

Check, for a GitHub-tracked project: the repository has the nine `rail:` labels within a minute of saving, Sync on the Issues page lists the repository's open issues, and an issue edited on GitHub changes in Rail within seconds. The App's Advanced tab lists each delivery with Rail's response, which is the place to look when one does not.

**A Rail on a laptop.** GitHub cannot reach `localhost`, so deliveries go through a relay. Create a channel at https://smee.io, make its URL the App's webhook URL, and run `npx smee-client --url https://smee.io/<channel> --target http://localhost:4000/webhooks/github` (with your `PORT`) while Rail runs. Signatures pass through unchanged.

## 7. Roles

Every stage runs as a role of the project: its agent CLI, model and prompt. A project without a role for a stage cannot start that stage. In Settings > Roles, either copy the roles of a project that has them (Copy roles) or create one per stage. The model each role names must be listed on a signed-in backend (`docs/machine-setup.md`, step 9).

Check: Settings > Roles lists a role for each of plan (with product, design and architect, which it runs as subagents), engineer, review, QA and demo for the project, and every model they name appears on a ready backend.

## 8. First task

Pick a small issue, claim it (Rail moves a tracker's status forward only once the issue has an owner), and start Plan. A run tab appears on the task within seconds. On a GitHub-tracked project the issue's label moves to `rail: in progress`, then `rail: in review` once review starts.
