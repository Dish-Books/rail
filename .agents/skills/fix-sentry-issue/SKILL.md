---
name: fix-sentry-issue
description: Fix a production error reported in Sentry end-to-end - pull the Sentry issue, open a Linear bug issue for it, reproduce the failure with a test, fix it with TDD, run mix test/credo/format gates without shortcuts, self-review the diff like a senior engineer, record a demo video when the symptom was visible, then commit and open a PR linked to the Linear issue (and resolve the Sentry issue). Use when the user hands off a Sentry issue ID/URL or asks to "fix this Sentry error".
---

# Fix Sentry Issue

End-to-end workflow for a production error: Sentry issue → Linear bug issue → reproduce with a failing test → fix (TDD) → gates → self-review → commit → PR linked to Linear (and resolve Sentry). Each phase must finish before the next begins.

This mirrors the [complete-issue](../complete-issue/SKILL.md) implementation flow, with two differences: there is no pre-written engineering plan (a Sentry crash is the spec), and this skill *creates* the Linear issue rather than reading one. The diagnosis of the error is the plan — keep it light and grounded in the stack trace, not a redesign.

**Not to be confused with [triage-inbox](../triage-inbox/SKILL.md).** That skill sweeps the whole unresolved Sentry queue into `Triage` tickets without diagnosing anything, so the errors get planned later alongside everything else. This skill takes **one** error and fixes it end to end, right now. Use this one when the user hands over a specific Sentry issue; use `triage-inbox` when they want the queue logged.

## 1. Pull the Sentry issue and diagnose

- **Sentry reference in args** (a `sentry.io/...` URL or an issue short id like `DISHBOOKS-AB`): fetch the issue, its latest event, and the full stack trace. Use the Sentry MCP tools if they are connected; otherwise ask the user to paste the issue title, culprit, stack trace, and a representative event (breadcrumbs, request params, release, frequency).
- **Pasted error / freeform prompt in args**: treat that as the source of truth.
- **No args**: ask the user for a Sentry issue ref or the error details before continuing.

From the event, extract: the exact exception type and message, the culprit (file:function:line), the failing frame in *our* code (skip framework frames), the input that triggered it, the release/commit, and how often it fires. Read the implicated source files and trace how the bad state reaches the failing line — confirm the root cause, do not just pattern-match the message. Multi-tenant accounting platform: check whether the crash is tenant-scoped and whether any data was written in a bad state before it failed.

Restate to the user in 1-2 lines: what the error is, where, the root cause you found, and the fix you intend. Get a quick confirm before creating anything.

## 2. Open the Linear bug issue and start

Create the issue with `save_issue` from the Linear MCP:

- **Title**: a crisp description of the bug (not the raw exception string), e.g. "Bill item totals crash when quantity is nil".
- **Description**: the problem, the root cause, the Sentry culprit and a representative stack trace, frequency/impact, and the intended fix. No em dashes (AGENTS.md writing style).
- **Team**: infer from the affected context; if you cannot tell, ask. Add the **Bug** label.
- **Link the Sentry issue**: pass the Sentry URL in `links` (e.g. `[{url, title: "Sentry issue"}]`) so the two are connected from the Linear side.
- **Assignee**: the engineer running the skill — pass `assignee: "me"`.
- **State**: `In Progress`.

Then **check out the issue's branch** from the `branchName` / `gitBranchName` on the `get_issue` / `save_issue` result (e.g. `dis-812-...`), creating it from that name if it does not exist. This branch name carries the issue id, so the PR opened from it auto-links back to the Linear issue. The Linear branch wins over any session/harness-provided `claude/...` branch, and this skill is your standing permission to use it without asking.

## 3. Reproduce, then fix test-first

Before any work run `MIX_ENV=test mise exec -- mix setup`.

Hand the diagnosis to the [tdd](../tdd/SKILL.md) skill. The **first** cycle is a reproduction test: write a test that drives the exact input from the Sentry event and asserts the correct behavior — it must fail with the *same* error Sentry reported (a red that reproduces the production crash). Only then make it green with the smallest fix at the root cause. Add further cycles for adjacent cases the fix implies (the nil that crashed here probably crashes its siblings too). Vertical slices only — one test → one implementation per cycle. Keep extended thinking light; fix the root cause, don't redesign the area.

## 4. Pre-commit gates

Run all of these sequentially via Bash with the sandbox disabled (Mix's PubSub needs a real TCP socket). **All must pass before commit.**

### 4a. `mise exec -- mix coveralls`
Forbidden routes to green: `@tag :skip`/`:pending`, deleting or commenting out tests, weakening assertions. Fix the underlying behavior; if a test is genuinely wrong, fix it for the right reason and explain. Coverage should report 100%; `mix coveralls.detail` shows any uncovered line.

### 4b. `mise exec -- mix credo`
Always on the **whole project**, never a path filter. Forbidden: editing `.credo.exs`, adding `# credo:disable-*` comments, or deleting flagged code to silence it. Fix the underlying issue. The [tdd](../tdd/SKILL.md) skill ran this at the end of every slice, so it should pass first time; if it doesn't, something escaped the per-slice check and the fix belongs at the root.

### 4c. `mise exec -- mix format`
Always on the **whole project**. Re-stage anything it rewrites.

If any gate fails, loop back into the [tdd](../tdd/SKILL.md) cycle, fix the root cause, then re-run **all gates from the top**.

## 5. Hunt for the same bug elsewhere

A Sentry crash is usually one instance of a class of bug. With the root cause now understood, search the codebase for other places that share it: the same unguarded call shape, sibling fields that take the same nil/bad input, other callers of the failing function, the same pattern copy-pasted into a neighboring context. Use the root cause (not the error string) as the search — e.g. if the crash was an unhandled nil quantity in a total, grep every place quantities feed a total.

List each candidate site to the user as `path:line` with one line on why it is at risk and how confident you are it is the same bug. Then **stop and confirm with the user how to handle them** via `AskUserQuestion` — do not silently fix or silently skip. The realistic options per site (or as a batch):

- **Fix here, same PR** — it is clearly the same bug and in scope; fold it into this branch with its own TDD cycle (failing test → fix → green), then re-run the step 4 gates.
- **Separate follow-up issue** — real but out of scope for this fix; open a Linear bug issue (steps 2's shape) capturing it, linked/related to this one.
- **Not actually affected** — you confirmed it is guarded or unreachable; record why in one line and move on.

Carry whatever the user chooses into the PR body (what was fixed here vs. what was filed as follow-up) so the scope is explicit.

## 6. Self-review before the PR

Engage the **highest extended thinking ("ultrathink")** here. This is the senior-engineer review on your own diff *before* the PR exists, so findings get fixed instead of posted. There is no CodeRabbit at this stage.

- **Apply CodeRabbit's rules yourself.** Read the `path_instructions` in [.coderabbit.yaml](../../../.coderabbit.yaml) that match the changed paths and apply them to the diff.
- **The senior-engineer layer.** Is the fix at the right level, or a band-aid above the real cause? Could the same root cause crash elsewhere (sibling fields, other callers) that this diff leaves unfixed? Walk the user-facing flow. Imagine the 2am page. Lead with the dimensions that carry the most risk for a multi-tenant accounting platform: tenant isolation and money.
- **Look for what is absent.** A test for the failing branch (you have it — confirm it truly reproduces the original crash), a guard at the boundary so bad input never reaches here again, a doc/glossary update, stale `CONTEXT.md`.

Get the diff locally (`git diff` against base, `git diff --staged`), not from a PR. Capture findings as `[severity] [category] path:line / Problem / Why / Fix`; severity blocker/high/medium/nit. Auto-fix clear correctness/simplicity/security findings by looping back through [tdd](../tdd/SKILL.md) (new failing test → fix → green); use `AskUserQuestion` only for genuinely ambiguous design calls. Drop mechanical style the gates already cover. After fixes, re-run all step 4 gates once more.

## 7. Record a demo when the symptom was visible

If the bug had a **visible symptom**, record the fixed behavior with the [record-demo-video](../record-demo-video/SKILL.md) skill. Drive the exact input from the Sentry event — the same flow that produced the crash, now completing. That is the clearest possible evidence the production failure is actually gone, and it is stronger than a green test because it exercises the real page.

**Record when** a user could see the failure: a crashed or blank page, an error flash, a workflow that dead-ended, a wrong number on screen, an export that failed.

**Skip it when** there is nothing to point a camera at: a background job or Oban worker, an API-only path, a crash in a scheduled task, or a fix whose only observable is the absent exception. Say in one line that you skipped it and why.

Have it upload to the Linear issue and return the `assetUrl`, so step 8 just writes the link.

**Scrub before recording.** Sentry events routinely carry real customer data. Reproduce the crash with **equivalent synthetic data**, never a real tenant's records — a demo video is as public as the PR it is attached to, and unlike a stack trace nobody redacts a video afterwards.

## 8. Commit, open the PR, close the loop

- Commit on the issue branch with a clear message describing the fix (no em dashes, no secrets/PII from the stack trace).
- Push and open the PR with `gh pr create`: title and body summarizing the bug, root cause, and fix, and linking the Linear issue id (e.g. `DIS-812`) so Linear connects the PR to the issue. Mention the Sentry issue.
- **Publish the demo video** if you recorded one in step 7, following [record-demo-video](../record-demo-video/SKILL.md)'s publishing section. GitHub has no API for attaching media, so upload it to the **Linear issue** and put a **markdown link to the returned `assetUrl`** in the PR description under a `## Demo` heading, with one line on what it shows. A link works because it carries the reviewer's Linear session; an `![]()` embed does not, because GitHub's camo proxy is unauthenticated and will 403. Never commit the mp4 to the repo to get around this. If you skipped the recording, say so in one line with the reason.
- Move the Linear issue to **In Review** (`save_issue` with `state: "In Review"`).
- **Resolve the Sentry issue** (or mark it resolved-in-next-release) if the Sentry MCP is connected; otherwise tell the user to resolve it once the PR merges.

CodeRabbit and CI then run on the PR as the mechanical backstop.

## Notes

- Never paste secrets, tokens, or PII pulled from the Sentry event into the Linear issue, commit message, or PR body. Sentry events routinely carry request bodies and user data; scrub before quoting.
- **No em dashes** in any output (AGENTS.md writing style). Use commas, colons, semicolons, or parentheses.
