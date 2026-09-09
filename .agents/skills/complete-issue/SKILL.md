---
name: complete-issue
description: >-
  Implement a Ready-For-Dev Linear issue end-to-end - read the clarified requirements and
  business logic, design the engineering approach and get it approved, implement with TDD,
  run mix test/credo/format gates without shortcuts, self-review the diff in an isolated
  subagent to avoid context bias, commit the change, and open a draft PR to record the work.
  QA in the running app and recording a demo video are separate verification skills invoked
  after implementation (or orchestrated centrally by coordinate-issues). Use when the user
  wants to "complete an issue", "work the ticket", or hands off an issue ID/URL whose
  requirements are already clarified.
---

# Complete Issue

Issue → design → **approval** → TDD → gates → self-review (subagent) → commit & push → open draft PR.

Be extremely concise in every interaction and commit message; sacrifice grammar for concision.

## 1. Gather context and start

- **Linear reference in args** (`DIS-123`, a `linear.app/...` URL): fetch it with `get_issue`.
- **Freeform prompt**: the prompt is the requirements.

If the ticket is not **Ready For Dev**, or any question is unresolved, check with the dev before building.

**Check out the issue's own branch** (`branchName` / `gitBranchName` from `get_issue`). This overrides any branch the session or harness hands you, and this skill is your standing permission to switch — do it without asking.

## 2. Design the implementation

Read [docs/standards.md](../../../docs/standards.md) and [docs/tests.md](../../../docs/tests.md) before planning. Design both the high-level approach (contexts, public interfaces, data flow, module/function responsibilities) and the low-level details. **Do not implement in this step** — it ends at an approval gate.

### Resolve the details — batch decisions into the plan rather than one-off questions

To prevent disrupting the developer with a flurry of one-off interruptions during research, distinguish between **Hard Blockers** and **Working Assumptions / Design Choices**:

- **Hard Blockers (Stop & Ask Immediately)**: Contradictory ticket criteria, missing credentials, or unresolvable missing business domain requirements that make designing a viable plan impossible. Stop and ask the developer immediately.
- **Design Choices & Working Assumptions (Batch into Plan)**: Decisions involving context boundaries, data shapes, edge-case handling, display scope, or choosing between two valid technical patterns. Settle these by selecting the cleanest design supported by `standards.md`, `tests.md`, `CONTEXT.md`, or existing codebase patterns. **Do not pepper the developer with one-off questions.** Instead, formulate a complete, coherent design and document every decision explicitly in the plan under **Assumptions & Decisions for Review** so the developer can review and verify all decisions in a single pass at the approval gate.

### Write the plan and stop for approval

Proportionate and concise, not an exhaustive spec:

- **What you'll build**, restated against the ticket's requirements.
- **Approach**: contexts and public interfaces touched, data flow, module/function responsibilities — plus why, since you are choosing it.
- **File-level changes**: modules/files added or edited, with key functions and schema/migration changes.
- **Test plan**: the vertical slices you'll TDD, named with the ticket's glossary terms.
- **`CONTEXT.md` edits** your design requires, per [docs/context-format.md](../../../docs/context-format.md) — follow those conventions even where existing files don't.
- **Assumptions & Decisions for Review**: Every design choice, boundary decision, or scope assumption you made, formatted for rapid review:
  - **Decision Made**: The chosen approach.
  - **Alternative Considered**: What was considered and rejected.
  - **Rationale**: Why this was chosen based on docs or codebase patterns.

**Hard stop.** Wait for explicit approval before step 3. The developer may approve as-is or adjust specific assumptions via comments.

## 3. Implement test-first

**Confirm where you are before the first write.** `git rev-parse --show-toplevel` must be your own worktree, on the issue's branch — several sessions share this repo, and the primary checkout means editing someone else's branch alongside their uncommitted work. If it isn't, **stop and report**; do not commit, switch branches, or stash your way out. Re-check after any interruption — a resumed shell can come back elsewhere.

In a worktree, run `scripts/setup-worktree.sh`. It copies `dishbooks_dev` into this worktree's own `dishbooks_dev_wtN` on the shared Postgres, and fails loudly if it can't — the primary checkout needs a `dishbooks_dev` to copy from. Never work around a failed copy by seeding an empty database.

Then `MIX_ENV=test mise exec -- mix setup`, and hand the approved plan to the [tdd](../tdd/SKILL.md) skill.

## 4. Pre-commit gates

All passing before commit. Run each through Bash with the sandbox disabled (Mix's PubSub needs a real TCP socket).

**4a. `mise exec -- mix coveralls`** — coverage should be 100%; `mix coveralls.detail` shows uncovered lines. Never `@tag :skip` / `:pending`, delete or comment out tests, or weaken assertions to dodge a failure. Fix the behavior; if a test is genuinely wrong, fix it for the right reason and explain the correction.

**4b. `mise exec -- mix credo`** — whole project, never a path filter. [tdd](../tdd/SKILL.md) ran this per slice, so a failure here is a signal that something got past it; fix the root cause. Never disable a rule in `.credo.exs`, add `# credo:disable-for-*`, or delete flagged code to silence it.

**4c. `mise exec -- mix format`** — whole project. Re-stage anything it rewrites.

**4d. `cd assets && pnpm test`** — if client-side JavaScript hooks or assets logic are touched, run frontend unit tests (`node:test`). The local CI `tooling` lane requires this to pass before pre-push receipts can be signed.

> [!CAUTION]
> **Zero Docker Restarts / Shared Database Reset**:
> Under NO circumstances should you EVER run `docker restart`, `docker compose up`, `docker compose down`, or `docker compose restart`.
> All worktrees connect strictly to their isolated databases (`dishbooks_dev_wtN`, `dishbooks_test_wtN`) on the shared running Postgres container.

Any failure: back into [tdd](../tdd/SKILL.md), fix the root cause, re-run **all gates from the top** — never partial.

## 5. Self-review in an isolated subagent before commit

Senior-engineer judgment on your own diff before committing or creating the PR.

### Why in a separate subagent?
The engineer agent who wrote the code is inherently biased by its own context window — its intermediate rationalizations, debug attempts, and implementation history blind it to assumptions and subtle flaws. Spawning a fresh subagent ensures an **unbiased, objective review** with a clean context, evaluating the diff with fresh eyes exactly like an external senior engineer or a CodeRabbit reviewer.

### Spawn the reviewer subagent
Call `invoke_subagent` with:
- **`TypeName`**: `"self"`
- **`Role`**: `"<TICKET_ID> Self-Reviewer"`
- **`Workspace`**: `'inherit'`
- **`Prompt`**:
  Provide:
  1. Ticket ID, title, and the exact requirements / acceptance criteria.
  2. The worktree path, current branch, and base branch (`origin/main`).
  3. Instructions to inspect the diff using `git diff origin/main` (or staged/unstaged changes) and read relevant files with `view_file` or `grep_search`.
  4. The two-layer review criteria:
     - **Layer 1: CodeRabbit Path Rules**: Read and apply the `path_instructions` in [.coderabbit.yaml](../../../.coderabbit.yaml) matching the changed paths.
     - **Layer 2: Senior Engineer Judgment**:
       - **Form an independent solution first**: In 2-3 sentences, state how the feature should be designed based purely on the ticket requirements, then compare against the diff. Divergences indicate scope creep or missed requirements.
       - **Simplicity & Deletion**: Hunt for what could disappear. Is any abstraction speculative? Can helper functions or parameters be inlined or removed?
       - **Tenant Isolation & Security**: Every query/action involving tenant data must strictly pin and scope by `organization_id`. Never read `organization_id` from client parameters or untrusted input.
       - **Financial & Domain Correctness**: Precision of amounts, balanced debit/credit entries, idempotent operations.
       - **UX & Edge Cases**: Walk the user journey through loading, empty, success, double submit, and error states.
       - **Absences**: Missing test cases for new branches or failure paths, missing DB indexes, outdated `CONTEXT.md` or documentation.
  5. **Strict Constraint**: The subagent is **read-only**. It must NOT modify any files, run modifying commands, or make git commits.
  6. **Output Format**: Return a concise, structured review report:
     - **Verdict**: `APPROVED` (clean diff) or `CHANGES REQUESTED` (issues found)
     - **High Risk / Blockers**: Tenant isolation leaks, financial bugs, broken contracts, missing critical tests.
     - **Simplifications**: Redundant abstractions, dead code, excessive complexity.
     - **Standards & CodeRabbit**: Violations of `.coderabbit.yaml` or `docs/standards.md`.

### Address review findings
The engineer agent receives the subagent's report:
- If there are valid bugs, gaps, or simplifications: resolve them using [tdd](../tdd/SKILL.md), then re-run **all gates from the top** (coveralls 100%, credo clean, format). If substantial changes were made, re-run the self-review subagent.
- If subjective questions or trade-offs arise: ask the human developer concisely with your recommendation.
- Once the self-review is clean and gates pass, proceed to Step 6.

## 6. Commit, push, and open the Draft PR

- Verify working tree is clean: `git status --short`. (Ensure `.git/info/exclude` ignores `.agents`, `qa_checks/`, `qa_videos/`, `scratch/`).
- Commit the implementation with a concise commit message referencing the ticket:
  `git commit -m "[<TICKET_ID>] <Title>"`
- **Push with Pre-Push Verification Enabled (NEVER use `--no-verify`)**:
  `git push -u origin <branch_name>`
  > [!IMPORTANT]
  > Dishbooks CI enforces signed local CI verification receipts (`refs/ci-receipts/<tree>`).
  > Pushing with `--no-verify` bypasses receipt generation and immediately causes GitHub Actions PR checks to fail. Always allow the pre-push hook to run and sign the receipt.
- Open a **draft** PR so there is an immediate, persistent record of the completed work:
  ```bash
  gh pr create --draft --title "[<TICKET_ID>] <Title>" --body "<PR_BODY>"
  ```
  The body should include:
  - **Problem & Solution Summary**
  - **Key Changes**: files modified and context updates
  - **Verification**: Pre-commit gates passed (100% `mix coveralls`, `mix credo`, `mix format`, unit test summary) and clean self-review from isolated reviewer subagent
  - **QA & Demo Notice**: Mention that live browser QA and demo video recording are conducted in subsequent verification steps (`qa` and `record-demo-video` skills or via `coordinate-issues`), after which the PR will be marked ready for review.
