---
name: coordinate-issues
description: >-
  Coordinate parallel subagents to implement multiple Linear issues or tickets concurrently
  using isolated worktrees, mandatory individual implementation plans with user approval gates,
  per-ticket fast-path parallel QA and demo video pipelines as soon as ready, continuous intake
  of additional tickets mid-conversation with slot recycling, context window cleanup protocols,
  PR review resolution, and post-merge teardown. Activate when the user provides Linear tickets
  to coordinate, adds more tickets to the current batch, or requests subagent issue orchestration.
---

# Coordinate Issues (Multi-Ticket Autonomous Delegation)

Act strictly as the coordinator / orchestrator between the user and specialized subagents. **The coordinator has NO responsibility for review resolution, coding, testing, or QA, and does NO hands-on work at all.** All actual work—research, implementation plans, code changes, pre-commit gates, browser QA, demo recordings, and resolving PR review comments—is executed exclusively by subagents inside their isolated git worktrees. The coordinator purely provisions workspaces, marks ticket status, relays instructions and approvals, tracks status on the dashboard, and reports progress to the user.

### Strict Coordinator Invariants & Anti-Patterns
- **NEVER run browser QA, demo recording, or test scenarios in the primary agent thread.** All browser driving and testing belong strictly in dedicated subagents.
- **NEVER poll or watch PR checks via CLI loops (e.g. `gh pr checks --watch`).** Do not block or poll on PR state; stand by reactively for notifications or reviewer feedback.
- **NEVER inspect code diffs, write code, or attempt PR fixes in the primary thread.** All code editing and review resolutions belong exclusively to the ticket's engineer subagent.

```text
Incoming Tickets (Initial Batch or Dynamically Added at Any Point)
               │
               ▼
Phase 0: Dynamic Workspace & Slot Manager
         (Allocate lowest free slot N, port 4000+100*N, DB wtN; recycle torn-down slots)
               │
               ▼
Phase 1: Parallel Design & Individual Implementation Plans
         (Each subagent formulates plan, sends to Coordinator, and STOPS)
               │
               ▼
Phase 2: Coordinator Plan Consolidation & User Approval Gate
         (Present plans to user; wait for explicit approval before coding starts)
               │
               ▼
Phase 3: Implementation, 100% Gates, Self-Review Subagent, & Draft PR
         (TDD, mix coveralls 100%, credo, format, self-review subagent, commit, push, draft PR)
               │
               ▼
Phase 4: Fast-Path Parallel QA & Demo Video (Triggered Per-Ticket As Soon As Ready!)
         ┌─────────────────────────────────────────────────────────────┐
         │ Runs IMMEDIATELY as each ticket finishes Phase 3.           │
         │ No global barrier. Multiple tickets run QA/Demo in parallel!│
         ├──────────────────────────────┬──────────────────────────────┤
         │ QA Subagent (qa skill)       │ Demo Producer (record skill) │
         │ Real browser against port wtN│ Headless CDP scenario record │
         │ Logs & console drain         │ Direct Linear MCP attachment │
         └──────────────────────────────┴──────────────────────────────┘
               │
               ▼
Phase 5: PR Review Resolution & Mark Ready (CodeRabbit & team review handling)
               │
               ▼
Phase 6: Post-Merge Teardown & Slot Recycling (drop DBs, prune worktree, free slot N)
               │
               ▼
Continuous Context Window Hygiene (offload artifacts, compact state, retire finished subagents)
```

---

## Phase 0: Dynamic Workspace & Slot Manager

The coordinator can be invoked initially with a list of tickets (e.g. `/coordinate-issues DIS-913 DIS-1248 DIS-1051`) **or** accept new tickets mid-flight at any point in the conversation (e.g. `"also coordinate DIS-1100"`, `"add DIS-1084 to the batch"`).

### Dynamic Slot Pool
Maintain an active slot pool:
- Dedicated slot `N` (`N = 1, 2, 3...`)
- Dedicated ports: Phoenix Web `4000 + 100*N`, Assets `4001 + 100*N`
- Dedicated databases: `dishbooks_dev_wtN`, `dishbooks_test_wtN`
- **Slot Recycling**: When a ticket PR merges and Phase 6 teardown completes, its slot `N` is freed and returned to the pool. When a new ticket arrives, allocate the lowest available slot number (reusing recycled slots first).

### Onboarding Steps for Each Ticket
For each newly arrived ticket:
1. **Fetch Issue Context**: Call Linear MCP tool `get_issue` (under `dishbooks-linear` or `linear`) with the issue identifier to get requirements, acceptance criteria, and git branch name (`gitBranchName` or `branchName`).
2. **Mark Ticket In Progress**: When provisioning the slot, immediately mark the Linear ticket as "In Progress" using the Linear MCP tool `save_issue` (resolve the "In Progress" `stateId` via `list_issue_statuses` for the ticket's team if not already cached).
3. **Create Isolated Worktree**:
   ```bash
   git worktree add -b <branch-name> <worktree_path> origin/main
   (cd <worktree_path> && ./scripts/setup-worktree.sh)
   ```
   Worktree path: `<worktree-root>/<ticket-slug>` (or standard worktree directory).
4. **Link Project Skills & Configure Git Exclude**:
   In the worktree root, link the project skills and ensure untracked symlinks/artifacts are ignored by pre-push clean-tree checks:
   ```bash
   ln -sf /Users/michael/Code/Dishbooks/dishbooks/.agents <worktree_path>/.agents
   mkdir -p <worktree_path>/.git/info
   printf ".agents\nqa_checks/\nqa_videos/\nscratch/\n" >> <worktree_path>/.git/info/exclude
   ```
5. **Compile Assets**:
   ```bash
   mise exec -- mix assets.setup && mise exec -- mix assets.build
   ```
6. **Update Central Coordination Dashboard**:
   Create or update `<appDataDir>/brain/<conversation-id>/subagent_coordination_status.md` with:
   - Ticket ID & Title
   - Branch Name & Worktree Path
   - Assigned Slot `N` & Port
   - Lifecycle Phase & State
   - Plan Status
   - QA Result & Evidence
   - Demo Video URL
   - PR Link & Review Status

---

## Phase 1: Parallel Design & Individual Implementation Plans

Spawn an implementation subagent for each ticket concurrently using `invoke_subagent` to research the problem and formulate an individual implementation plan.

### Subagent Invocation Specification
- **`TypeName`**: `"self"`
- **`Role`**: `"<TICKET_ID> Engineer"` (e.g. `"DIS-913 Engineer"`)
- **`Prompt`**: Must contain:
  1. Ticket ID, title, branch name, assigned slot `N`, and absolute worktree path.
  2. The clarified requirements and acceptance criteria.
  3. Instruction to follow `complete-issue` and `tdd` skills.
  4. **CRITICAL SYSTEM SAFEGUARDS**:
     > "- Under NO circumstances should you EVER restart, stop, or execute Docker Compose commands (`docker compose up`, `docker compose down`, `docker restart`, etc.). The shared Postgres container must remain running undisturbed.
     > - Connect strictly to your isolated slot databases (`dishbooks_dev_wtN`, `dishbooks_test_wtN`).
     > - Pre-push quality gates must NEVER be skipped with `--no-verify`. GitHub Actions `pr.yaml` strictly requires cryptographic local CI receipts pushed to `refs/ci-receipts/<tree>`.
     > - If client-side JavaScript hooks or assets logic are touched, run frontend unit tests via `cd assets && pnpm test`."
  5. **MANDATORY IMPLEMENTATION PLAN GATE**:
     > "Before writing ANY production code, database migrations, or test files, you MUST write an individual implementation plan covering:
     > - What you will build restated against the requirements
     > - High-level approach and context boundaries
     > - Files to add or modify (functions, schemas, migrations)
     > - TDD test plan (vertical slices and edge cases)
     > - `CONTEXT.md` updates required
     > - **Assumptions & Decisions for Review**: Every working assumption, scope boundary, or chosen pattern, formatted with Decision Made, Alternative Considered, and Rationale.
     > 
     > Send this implementation plan to the coordinator via `send_message`.
     > 
     > **HARD STOP**: You MUST STOP and WAIT for the coordinator to reply with explicit user approval before writing any code or tests."
  6. **Hard Blockers vs. Working Assumptions**:
     > "Do NOT interrupt the coordinator/user with a flurry of one-off questions during research. Settle design choices, data shapes, and scope boundaries by selecting the cleanest pattern and documenting it clearly under 'Assumptions & Decisions for Review' in your plan. Only message the coordinator immediately if you hit a Hard Blocker (contradictory ticket criteria or missing credentials) that prevents designing a plan."
  7. **Token-Efficient Messaging**:
      > "Keep your plan and status updates concise. Do not dump raw file contents or verbose logs into messages."
  8. **Pre-Commit Gates, Self-Review Subagent, Push, and Draft PR (Post-Approval)**:
     After receiving approval from coordinator: follow `complete-issue` to ensure 100% test coverage (`mise exec -- mix coveralls`), Credo clean (`mise exec -- mix credo`), formatted (`mise exec -- mix format`), frontend tests (`cd assets && pnpm test` if JS touched), spawn an isolated self-review subagent to review the diff against `origin/main`, resolve any findings, commit changes locally, push to origin with pre-push hooks enabled (NEVER `--no-verify`), and open a draft PR with `gh pr create --draft`.
  9. **Completion Notification**:
     Notify coordinator via `send_message` with your commit hash and draft PR URL.

---

## Phase 2: Coordinator Plan Consolidation & User Approval Gate

1. **Collect Plans**: As each engineer subagent sends its implementation plan via `send_message`, review and record it in the coordination dashboard.
2. **Consolidate & Surface Assumptions**: Consolidate individual ticket plans into `<appDataDir>/brain/<conversation-id>/implementation_plan.md` (`RequestFeedback: true`, `UserFacing: true`). Prominently aggregate all subagents' **Assumptions & Decisions for Review** into a top-level **User Review Required: Key Assumptions** section. This allows the human user to audit all architectural decisions across all parallel tickets in one coherent, single-pass review.
3. **Obtain Explicit Approval**: **STOP** and wait for the human user's explicit approval or artifact comments before dispatching execution.
4. **Dispatch Approvals & User Corrections**: Once the user approves (or provides feedback/corrections on specific assumptions via comments):
   - Send approval messages via `send_message` to each waiting engineer subagent.
   - If the user corrected or adjusted any assumptions (e.g. "don't show proration on billing settings", "schema only needed if list starts empty"), include the user's exact corrections in that subagent's approval message so the engineer adjusts its plan accordingly before writing code:
     > "Your implementation plan has been approved by the user with the following adjustment: '<USER_CORRECTION>'. You may now proceed with TDD implementation, pre-commit gates, self-review subagent, local commit, push, and opening a draft PR per complete-issue."

---

## Phase 3: Parallel Implementation, Gates, Self-Review, & Draft PRs

Subagents implement test-first via `tdd` and follow `complete-issue`:
1. Implement features and tests in assigned worktree.
2. If any architectural questions arise, subagent surfaces them to coordinator, who asks user.
3. Run all pre-commit gates in the worktree:
   - `mise exec -- mix coveralls` (100% coverage)
   - `mise exec -- mix credo` (clean across the project)
   - `mise exec -- mix format`
4. Spawn an isolated self-review subagent (`complete-issue` step 5) to inspect the diff against `origin/main` without context bias, and resolve any findings.
5. Commit changes locally to git with a clear commit message referencing the ticket: `git commit -m "[<TICKET_ID>] <Title>"`.
6. Push branch to origin (`git push -u origin <branch_name>`).
7. Open draft PR (`gh pr create --draft`) so the work is recorded immediately.
8. Report completion with commit hash and draft PR link to coordinator via `send_message`.

---

## Phase 4: Fast-Path Parallel QA & Demo Video (Triggered Per-Ticket As Soon As Ready)

**NO GLOBAL BLOCKING BARRIER**:
Do **NOT** wait for all tickets to finish implementation before starting QA or demo videos. The instant any individual ticket finishes Phase 3 and opens its draft PR, that ticket transitions immediately into Phase 4.

### Parallel Execution Across Tickets
Because every ticket has an isolated worktree slot `N`, distinct port range (`4000 + 100*N`), and isolated database (`dishbooks_dev_wtN`), multiple tickets run their QA and demo video pipelines concurrently without interference.

### Per-Ticket QA & Demo Workflow
As soon as Ticket `<TICKET_ID>` enters Phase 4:

1. **Start Dev Server on Slot Port**:
   Run the dev server in the ticket's worktree:
   ```bash
   .agents/skills/qa/scripts/qa.sh start
   ```
   (Uses port `4000 + 100*N` and connects to `dishbooks_dev_wtN`).

2. **Run QA and Demo Video in Parallel / Pipeline**:
   - **Verified Pipeline (Default & Recommended)**:
     1. **Spawn QA Subagent**:
        - `TypeName`: `"self"`, `Role`: `"<TICKET_ID> QA Engineer"`.
        - Instruct to follow `qa` skill (`.agents/skills/qa/SKILL.md`), drive real browser checks, inspect screenshots, and run `drainProblems()`.
        - Instruct to **leave dev server running** when done.
     2. **Handle QA Findings**:
        - If blockers or regressions are found, dispatch targeted fixes to the ticket's engineer subagent, re-run gates, and re-verify.
     3. **Spawn Demo Video Producer**:
        - Once QA is green, spawn `"<TICKET_ID> Demo Video Producer"` (`record-demo-video` skill).
        - Producer drives scenario against the active dev server, captures frames, encodes mp4, uploads directly to Linear issue via MCP (`prepare_attachment_upload` + `create_attachment_from_upload`), and reports `assetUrl`.
   - **Fully Concurrent QA & Demo**:
     If the demo scenario and QA checklist operate on independent, non-conflicting records/screens, the coordinator may launch the QA Subagent and Demo Producer concurrently against the running dev server for maximum velocity.

3. **Tear Down Dev Server & Update PR Description (Owned by Subagent)**:
   The Demo Video Producer subagent owns the final delivery steps before completing:
   - Updates the PR description using `gh pr edit <PR_NUMBER> --body ...` to prominently add:
     ```markdown
     ## Demo Video
     [Watch the demo](<assetUrl>) - <one-line description of the feature working>. Also attached to [<TICKET_ID>](https://linear.app/dishbooks/issue/<TICKET_ID>).
     ```
   - Marks the PR ready for review: `gh pr ready <PR_NUMBER>`.
   - Tears down the dev server: `.agents/skills/qa/scripts/qa.sh stop`.
   - Runs pre-push verification to sign and push the local CI receipt: `git push origin <branch_name>`.
   - The coordinator does NO manual PR editing or git commands.

---

## Phase 5: PR Review Delegation & Relay

**THE COORDINATOR DOES NO WORK AT ALL**:
The coordinator has zero responsibility for review resolution. It does NOT analyze review comments, inspect code, suggest code edits, or touch files. It is strictly a communication bridge between the user and the subagents.

When the user asks to address review comments (or when automated reviews arrive):
1. **Always Route Feedback to the Original Engineer Subagent**:
   - The coordinator **must send review comments back to the original `<TICKET_ID> Engineer` subagent via `send_message`**.
   - Do NOT spawn a new generic resolver subagent if the original ticket engineer subagent is still available, as the original engineer already holds the architecture and worktree context.
   - Instruct the subagent to handle the entire resolution in its isolated worktree:
     - Inspect unresolved comments via `gh api repos/Dish-Books/dishbooks/pulls/<PR>/comments` and `gh pr view <PR> --comments`.
     - Implement fixes and regression tests via `tdd`.
     - Pass all pre-commit gates: `mix coveralls` (100%), `mix credo`, `mix format`, and `cd assets && pnpm test` (if JS modified).
     - Commit and push to origin with pre-push hooks enabled (NEVER use `--no-verify`).
     - **Reply to & Resolve GitHub Review Threads**: Explicitly reply to each reviewer comment thread on GitHub explaining the fix and resolve the thread.

2. **Subagent Executes Entire Resolution**:
   The subagent alone owns the fix:
   - Modifies files exclusively inside its assigned worktree.
   - Runs full pre-commit verification gates.
   - Commits and pushes the updates to origin with signed receipt.
   - Replies to and resolves all GitHub review comment threads.
   - Messages the coordinator when finished with the commit hash and summary of addressed comments.

3. **Coordinator Reports Completion to User**:
   Upon receiving the subagent's completion message, the coordinator notifies the user and updates the status dashboard. It does not perform any code verification or PR polling itself.

---

## Phase 6: Post-Merge Teardown & Slot Recycling

When a ticket's PR is merged to `main`:
1. **Verify Merge**:
   ```bash
   gh pr view <pr_number> --json state,mergedAt,mergeCommit
   ```
2. **Safety Check**: Verify zero diff between worktree HEAD and `origin/main`.
3. **Drop Postgres Replication Slots**:
   ```bash
   docker compose -p dishbooks exec -T postgres psql -U postgres -c "SELECT pg_drop_replication_slot(slot_name);" 2>/dev/null || true
   ```
4. **Drop Worktree Databases**:
   ```bash
   docker compose -p dishbooks exec -T postgres dropdb --if-exists --force -U postgres dishbooks_dev_wtN
   docker compose -p dishbooks exec -T postgres dropdb --if-exists --force -U postgres dishbooks_test_wtN
   ```
5. **Terminate Processes**: Kill any lingering Phoenix or watcher processes on slot `N`.
6. **Remove Git Worktree**:
   ```bash
   git worktree remove <worktree_path>
   ```
7. **Fast-Forward Local Main**:
   ```bash
   git fetch --prune origin main:main
   ```
8. **Delete Local Branch**:
   ```bash
   git branch -D <branch_name>
   ```
9. **Confirm Linear Status**: Verify issue moved to `Done`.
10. **RECYCLE SLOT**:
    Mark slot `N` as **FREE** in the slot pool so any new ticket ingested mid-conversation can immediately reuse this slot, port block, and database name.
11. **Retire Subagents**:
    Terminate completed subagents for this ticket via `manage_subagents` (`Action: "kill"`).

---

## Context Window Hygiene & Token Management Protocols

Coordinating multiple parallel tickets across multiple batches in a single conversation generates high token volume. Strictly adhere to these protocols to prevent conversation token exhaustion and performance degradation:

### 1. Token Economy in Subagent Messaging
- **No Verbose Code Dumps**: Subagents must NEVER send full source files, large diffs, or hundreds of lines of compilation/test output over `send_message`.
- **Structured Concise Updates**:
  - *Implementation Plans*: Limited to bullet points of approach, files touched, and TDD checklist (< 50 lines).
  - *Gate Pass*: State `All gates passed: coveralls 100%, credo clean, formatted` with commit SHA.
  - *QA Report*: Send only the markdown summary table and failing items. Point to screenshot paths on disk instead of encoding images.
  - *Demo Producer*: Send only the Linear `assetUrl` and one-sentence description.

### 2. Externalize Detailed State to Artifacts on Disk
- Keep `<appDataDir>/brain/<conversation-id>/subagent_coordination_status.md` as the authoritative single source of truth. Update this file on every phase transition rather than outputting verbose essay summaries into the chat.
- Store ticket-specific scratchpads, check scripts, and scenario files inside `<worktree_path>/scratch/` or `<appDataDir>/brain/<conversation-id>/tickets/<TICKET_ID>/`.

### 3. Active Subagent Retirement
- Active subagents retain memory and transcript tracking context.
- Once a subagent finishes its phase (e.g. Engineer completes draft PR, QA engineer delivers findings, Demo Producer uploads video), terminate it using `manage_subagents` with `Action: "kill"` if no further revisions are required.
- Do not leave idle subagents lingering across unrelated ticket phases.

### 4. Coordination Status Compaction
- As tickets complete Phase 6 (Teardown & Merged), move their rows in `subagent_coordination_status.md` into an "Archived / Completed Issues" section.
- Keep the active view focused only on in-flight and newly queued issues.

### 5. Context Capacity Monitoring & Checkpoint Handoff
- If the conversation coordinates 4+ tickets or token usage approaches high levels:
  - Provide a concise context status report if requested or when reaching milestones.
  - If token exhaustion is imminent, the coordinator can write a `coordination_checkpoint.md` artifact detailing all active worktrees, branches, slots, and PRs, enabling seamless resumption in a fresh conversation with:
    `/coordinate-issues --resume`
