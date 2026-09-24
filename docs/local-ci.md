# Local CI

`mise run ci` runs every gate, then pushes a signed receipt. On a PR, GitHub verifies the receipt instead of repeating the work; the suite itself runs on GitHub only on merge to `main`. This is the dishbooks setup ([its docs/local-ci.md](https://github.com/Dish-Books/dishbooks/blob/main/docs/local-ci.md)) with Rail's gates.

```bash
mise run ci
```

| Lane | Gates |
|---|---|
| dev (`_build/dev`) | compile (clean, no warnings) → format, credo, deps.audit, sobelow |
| test (`_build/test`) | ecto.create/migrate, tests with coverage held at 100% |
| `credo/` | the subproject's own gates, coverage held at 100% |

The lanes run in parallel after a serial prelude that waits for Postgres at `DB_HOST`/`DB_PORT` and runs `deps.get`. A failing gate doesn't stop the others, so one pass shows everything that is broken.

`--fast` skips the clean rebuild and writes no receipt. `--no-push` keeps the receipt local. `--serial` runs the lanes one at a time.

## The receipt

Keyed on `HEAD^{tree}`, so amend, rebase or reword of an unchanged tree keeps it. `ci.sh` refuses to write one from a dirty working tree. The payload (tree, gates, toolchain versions) is HMAC-SHA256'd with `CI_RECEIPT_KEY` and pushed to `refs/ci-receipts/<tree>`.

`scripts/ci-verify-receipt.sh` rejects a receipt whose signature, tree, gate set or toolchain versions don't match. It cannot tell whether the gates passed, only that someone with the key says they did — a speed optimization on a trusted team, not a security boundary.

| Event | Workflow | What runs |
|---|---|---|
| Pull request | `pr.yaml` | `Verify Local CI` only |
| Push to `main` | `tests.yaml` | `scripts/ci.sh --fast` against a Postgres service; Slack on failure |

A PR with no valid receipt fails, with no fallback, so fork and Dependabot PRs need someone to push the branch from this repo and run `mise run ci`.

## The pre-push hook

`prek` installs a `pre-push` shim (`.pre-commit-config.yaml`) that runs the same lanes through `scripts/ci-lanes.sh`, one hook per lane. The prelude checks for a receipt first: when one covers the tree, every later hook no-ops, so `mise run ci` then `git push` doesn't pay twice. Otherwise the lanes run, a failing gate blocks the push, and the receipt hook signs and pushes the receipt. A receipt that exists only in this clone gets published.

Staged or untracked changes block the hook, since the gates would test a tree other than the one being pushed. `git push --no-verify` skips it. It is HEAD-based, so push from the branch you tested.

By hand, with no receipt pushed:

```bash
mise exec -- env CI_NO_PUSH=1 prek run --hook-stage pre-push --all-files
```

## Worktrees

`scripts/setup-worktree.sh` gives a worktree its own ports and `rail_dev<suffix>`/`rail_test<suffix>` on the shared Postgres, copies `rail_dev` and warms `deps`/`_build` from the primary checkout. Hand-made worktrees take slot N (ports `4050 + N*100`, clear of dishbooks' `4000 + N*100`); a worktree Rail made takes the ports Rail gives it. See the script's header for flags.

## Setup

`mise install` pins `prek` and installs the pre-push shim, once per clone. Put the shared key in the gitignored `.env`:

```bash
echo "CI_RECEIPT_KEY=<shared secret>" >> .env
```

In GitHub, add repo secrets `CI_RECEIPT_KEY` (same value) and `SLACK_WEBHOOK_URL`, and make `Verify Local CI` a required check.
