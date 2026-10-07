# Machine setup

What a machine needs before Rail runs on it, and how to tell it is ready.

**Checking a machine with an LLM.** Give this file to a coding agent (Claude Code, for example) on the machine and ask: "Go through docs/machine-setup.md. Run every check, tell me which pass and which fail, and for each failure the fix this file gives." Every item below has a check whose expected result is stated, so the agent never has to guess. It should only report and suggest; installing packages needs `sudo`, which is yours to run.

## 1. Toolchain (mise)

Elixir, Erlang, Node and the pre-push hook come from `mise.toml`.

- Install: `mise install` in the checkout.
- Check: `mise exec -- elixir --version` prints Elixir `1.19.5` on OTP `28`.

## 2. Postgres 17 on localhost

Rail and the projects it works on share one Postgres, user `postgres`, password `postgres`, on `localhost:5432` (`DB_PORT` overrides the port).

- Check: `pg_isready -h localhost -p 5432` says `accepting connections`.
- Check: `PGPASSWORD=postgres psql -h localhost -U postgres -c 'select version()'` shows PostgreSQL 17.

## 3. pgvector

The learnings tables store embeddings, so the first migration runs `CREATE EXTENSION vector`. Without the extension it fails with `extension "vector" is not available`.

- Check: `PGPASSWORD=postgres psql -h localhost -U postgres -Atc "select default_version from pg_available_extensions where name = 'vector'"` prints a version (for example `0.8.0`). Empty output means it is missing.
- Install, by how Postgres is installed:
  - Docker: run the `pgvector/pgvector:pg17-trixie` image, as `docker-compose.yml` does.
  - Homebrew: `brew install pgvector`.
  - Debian/Ubuntu: `sudo apt install postgresql-17-pgvector`.
- Ubuntu gotcha: the PostgreSQL apt repo (`apt.postgresql.org`, PGDG) stops publishing for an Ubuntu release once it is end of life. On Ubuntu 25.10 the install fails with `404 Not Found` from `questing-pgdg`. Install Ubuntu's own build instead, pinned so apt does not pick the dead PGDG one: `apt-cache policy postgresql-17-pgvector` lists it (it was `0.8.0-1`), then `sudo apt install postgresql-17-pgvector=<that version>`. Comment out `/etc/apt/sources.list.d/pgdg.list`, or `apt update` keeps failing on the same 404.
- No Postgres restart is needed: pgvector is not a preload library.

## 4. Chrome and ffmpeg

The QA and demo stages drive Chrome; a demo's frames are encoded with ffmpeg.

- Check: one of `google-chrome --version`, `chromium --version` or `chromium-browser --version` prints a version.
- Check: `ffmpeg -version` prints a version. Without it a demo still records, but its video cannot be encoded.

## 5. The agent CLI

Each stage runs an agent CLI. Rail's default roles use Claude Code.

- Check: `claude --version` prints a version, and `which claude` gives the absolute path the Backends page will need.

## 6. `.env`

Dev loads `.env` from the checkout root (and mise loads it into the shell). None of it is required to boot, but without the GitHub App Rail cannot clone, push or open pull requests.

| Variable | What it is | Needed for |
|---|---|---|
| `PORT` | Rail's HTTP port, default 4000 | running beside other Phoenix apps |
| `GITHUB_APP_ID` | the App's numeric id, not its client id | anything touching a repository |
| `GITHUB_APP_PRIVATE_KEY` | a path to the App's `.pem`, or the PEM itself | the same |
| `GITHUB_WEBHOOK_SECRET` | the secret set on the App's webhook | GitHub-tracked projects hearing about changes made on GitHub |
| `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET` | an OAuth App's credentials | signing in with GitHub (not needed with `/dev/login`) |
| `LINEAR_CLIENT_ID`, `LINEAR_CLIENT_SECRET` | Linear OAuth | Linear-tracked projects only |
| `SLACK_CLIENT_ID`, `SLACK_CLIENT_SECRET` | Slack OAuth | triage from Slack only |
| `ENABLE_GOTH=true` plus Google credentials | Vertex embeddings | learnings search |

`docs/org-setup.md` says how to get the GitHub values.

- Check: `grep -c '^GITHUB_APP_ID=' .env` prints `1`, and the key path in `GITHUB_APP_PRIVATE_KEY` exists (`test -f "$path"`). Keep the `.pem` outside the repo.

## 7. Database and server

- Install: `mix setup` (deps, database, migrations, assets).
- Check: `mix ecto.migrations` lists no migration as `down`.
- Run: `mix phx.server`.
- Check: `curl -s -o /dev/null -w '%{http_code}' http://localhost:${PORT:-4000}/_health` prints `200`.

## 8. Signing in

- Dev only: `http://localhost:${PORT:-4000}/dev/login` signs in as an admin, `qa-admin@rail.local`. `/dev/login/<email>` signs in as that email instead. Use your GitHub email, so a later GitHub sign-in becomes the same user rather than being refused as uninvited.
- GitHub: needs the OAuth App from `docs/org-setup.md`, with callback `http://localhost:${PORT:-4000}/auth/github/callback`. The first account through an empty instance becomes its admin; everyone after needs an invite.

## 9. An account for the agents

Settings > Backends has one card per agent CLI. A run is only placed on a backend that is signed in and lists the role's model.

- Set the executable to the absolute path from step 5, then sign in from the card.
- Add every model the roles use (Rail's default roles all use `claude-opus-5-5`).
- Check: the card says it is ready, and its model list is not empty. With an empty list every run is refused with "no account offers <model>".

After this the machine is ready. What a GitHub org and each repository need is in `docs/org-setup.md`.
