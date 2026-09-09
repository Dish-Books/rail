---
name: post-merge-cleanup
description: Tear down a worktree after its PR has merged - verify the merge, confirm no work would be lost, drop the worktree's databases from the shared Postgres, remove the worktree, fast-forward local main, delete the local branch, and confirm the Linear issue moved. Use when the user says a PR is merged and asks to "clean up the worktree", "tear this down", or finish off a completed branch.
---

# Post-Merge Cleanup

Retire a finished worktree. The work is already merged, so the only real risk is deleting something
that *wasn't* — verify before removing anything, in this order.

## 1. Verify the merge yourself

Don't take "it's merged" as proof. Check:

```bash
gh pr view <number> --json state,mergedAt,mergeCommit,headRefName
```

`state` must be `MERGED`. If it is `OPEN` or `CLOSED`, stop and tell the user — a closed-unmerged PR
means the branch holds the only copy of the work.

## 2. Confirm nothing would be lost

From inside the worktree:

- `git status --short` — must be empty.
- `git log origin/<branch>..HEAD --oneline` — must be empty. Commits here are unpushed and will be
  destroyed with the branch.

**On a merged PR the remote-tracking ref is usually already gone**, so that second command dies with
`unknown revision`. That is not a failure — GitHub deleted the branch on merge and a `--prune` fetch
dropped the ref. Fall back to comparing against `main`, which is the question you actually care
about:

```bash
git -C <worktree> log origin/main..HEAD --oneline
```

Expect this to be **non-empty** after a squash merge — see step 6. Content, not commit identity, is
what proves nothing is lost:

```bash
base=$(git -C <worktree> merge-base origin/main HEAD)
files=$(git -C <worktree> diff --name-only "$base" HEAD)
git -C <worktree> diff --stat origin/main HEAD -- $files
```

Empty output means every file the branch touched is identical to `main` — the work is in. Non-empty
means either `main` moved on those files afterwards or something genuinely did not land: read the
diff before going further.

If either is non-empty, stop and show the user what's there. Do not remove the worktree, and do not
offer to force it — let them decide what to keep.

**Never touch `git stash`.** The stash list is shared across every worktree in the repo and runs to
dozens of entries belonging to other branches and other people. It is not this worktree's state, it
is not yours to prune, and a dropped stash is unrecoverable. Same rule as everywhere else in this
repo: never `git stash`, never `git stash drop`, never `git stash clear`.

## 3. Drop the worktree's databases

All worktrees share one Postgres — the primary checkout's. A worktree owns only its own suffixed
databases, so cleanup is a `dropdb`, **not** `docker compose down -v`. The shared volume holds the
primary's real dev database and every other worktree's; `down -v` would destroy all of it.

Read the suffix from the worktree's `.env` rather than guessing:

```bash
grep DB_SUFFIX <worktree>/.env      # e.g. DB_SUFFIX=_wt3
```

An empty suffix means slot 0 — that is the *primary checkout*, not a worktree. Stop and say so;
`dishbooks_dev` is the real dev database.

First, terminate any running dev server / BEAM processes for the worktree. Active
connections or logical replication slots will block `dropdb` with `database is used by an active logical replication slot`.

Query and drop any active replication slots for this database:
```bash
docker compose -p dishbooks exec -T postgres psql -U postgres -c "SELECT slot_name FROM pg_replication_slots WHERE database = 'dishbooks_dev<suffix>';"
# For any active slot:
docker compose -p dishbooks exec -T postgres psql -U postgres -c "SELECT pg_drop_replication_slot('slot_name');"
```

Then drop both databases inside the shared Postgres container. Every worktree's
`COMPOSE_PROJECT_NAME` points at that one project, so this works from anywhere:

```bash
docker compose -p dishbooks exec -T postgres dropdb --if-exists --force -U postgres dishbooks_dev<suffix>
docker compose -p dishbooks exec -T postgres dropdb --if-exists --force -U postgres dishbooks_test<suffix>
```

Slots are reused: `setup-worktree.sh` allocates the next free `N` by scanning existing
`dishbooks_dev_wt<N>` databases, so leaving them behind permanently occupies a slot and pushes the
next worktree onto new ports. Dropping them is not just tidiness.

**Never pass an unsuffixed name**, and never run `docker compose down -v` for any project as part of
this cleanup.

## 4. Remove the worktree

Run from the primary checkout, not the worktree — you cannot remove the directory you're standing in:

```bash
cd /Users/michael/Code/Dishbooks/dishbooks
git worktree remove .claude/worktrees/<name>
```

## 5. Update local main

Do this *before* deleting the branch, not after. It pulls in the merge commit, which means the
`git branch -d` in step 6 can verify the work is genuinely in `main` rather than falling back on
"merged to its upstream".

Which command to use depends on whether `main` is checked out. Find out first:

```bash
git -C /Users/michael/Code/Dishbooks/dishbooks branch --show-current
git -C /Users/michael/Code/Dishbooks/dishbooks status --short
```

**Primary is on `main`** (the normal case) — pull it:

```bash
git -C /Users/michael/Code/Dishbooks/dishbooks pull --ff-only origin main
git -C /Users/michael/Code/Dishbooks/dishbooks fetch --prune origin
```

Needs a clean tree. If there are uncommitted changes, skip it, say so, and carry on with the rest of
the cleanup — never stash, check out, or discard to force the update through.

**Primary is on some other branch** — write the ref directly instead:

```bash
git -C /Users/michael/Code/Dishbooks/dishbooks fetch --prune origin main:main
```

This updates `main` without touching any working tree, so a dirty tree doesn't block it, and the
refspec is fast-forward-only by default (no leading `+`). Don't check `main` out just to pull it.

The catch: git refuses this when `main` is checked out in **any** worktree of the repo, not merely
the current one —

```
fatal: refusing to fetch into branch 'refs/heads/main' checked out at '/Users/michael/Code/Dishbooks/dishbooks'
```

— which is why the normal case above uses `pull` instead. If `main` is checked out in a *different*
worktree and you're not in it, both routes are refused; skip the update and say so.

Either way `--ff-only`/the bare refspec means a diverged local `main` fails loudly rather than
silently merging or rebasing. Report the divergence and let the user resolve it. `--prune` clears the
remote-tracking ref for the branch GitHub deleted on merge.

Other worktrees keep their own checked-out branches — updating `main` doesn't touch them.

## 6. Delete the local branch

```bash
git -C /Users/michael/Code/Dishbooks/dishbooks branch -d <branch>
```

Try `-d` first. It refuses to delete anything unmerged, which is the safety net for step 2. With main
updated in step 5 this is a real "is it in main?" check and should be silent. If it warns "merged to
remote but not yet merged to HEAD", the pull was skipped or didn't land — fine to proceed, just
weaker.

**A hard refusal usually means the PR was squash-merged, not that work is unmerged.** This repo
squash-merges, so a squashed branch's commits are by construction never ancestors of `main` and `-d`
can *never* succeed on one. Don't stop on the refusal alone, and don't reach straight for `-D`
either. Establish which case you're in:

```bash
sha=$(gh pr view <number> --json mergeCommit -q '.mergeCommit.oid')
git merge-base --is-ancestor "$sha" main && echo "merge commit is in main"
git rev-list --parents -n1 "$sha" | wc -w   # 2 => squash (1 parent), 3 => merge commit
```

`-D` is justified **only** with all of: the PR reports `MERGED`, its merge commit is an ancestor of
`main`, that commit has a single parent, and step 2's content check came back empty. That is four
independent confirmations the work is in `main`; the refusal is then an artifact of squashing.

Anything less — a missing merge commit, a content diff you can't explain, a `CLOSED` PR — means stop
and show the user. Never `-D` to make an inconvenient refusal go away.

The remote branch is usually auto-deleted on merge. Confirm rather than assume:

```bash
git ls-remote --heads origin <branch>
```

Empty output means it's gone. If it isn't, delete it with `git push origin --delete <branch>`.

## 7. Confirm the tracker caught up

Fetch the Linear issue. Merging normally moves it to **Done** automatically. If it's still
In Progress or In Review, say so and ask whether to move it — don't silently transition someone
else's ticket.

## 8. Report what you touched

State plainly what was removed (worktree, branch, databases), whether `main` was
updated and to what, and — just as important — what was deliberately left alone: the primary stack,
other worktrees, the shared stashes. Mention any follow-up tasks spawned during the work that are
still open.
