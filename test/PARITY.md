# Prototype → Rail Parity Matrix & Behavior Inventory Mapping

This document maps every behavior category and test row from **Spec 06 §4** (Behavior Inventory) to its Elixir test module in Rail.
It also accounts for all architectural differences and explicitly marks obsolete/superseded rows with references to **PLAN.md §3 and §15**.

---

## Parity Summary by Category

| Spec 06 Section | Category Name | Status | Primary Rail Test Modules |
|---|---|---|---|
| **§4.1** | Pipeline / Stage Machine | Parity Complete | `lib/rail/pipeline/actions/*_test.exs`, `lib/rail/pipeline_test.exs`, `lib/rail/e2e/ticket_lifecycle_test.exs` |
| **§4.2** | Attention Queue / Questions Inbox | Parity Complete | `lib/rail/domain/attention_queue_test.exs`, `lib/rail/domain/overview_queue_test.exs`, `lib/rail/pipeline/actions/*question*_test.exs` |
| **§4.3** | CLI Runner, Streams & Resumption | Parity Complete | `lib/rail/runs/*_test.exs`, `lib/rail/domain/stage_verdict_test.exs`, `lib/rail/domain/run_failure_test.exs` |
| **§4.4** | Architect Plan, Tickets & Golden Prompts | Parity Complete | `lib/rail/pipeline/utils/briefs_test.exs`, `lib/rail/domain/ticket_body_test.exs`, `lib/rail/pipeline/utils/scratch_test.exs` |
| **§4.5** | Sleep Prevention | Superseded / Obsolete | *Moot for server-hosted web app; omitted per PLAN.md §3, §15* |
| **§4.6** | Pull Requests: Conflicts, Drafts, Rebase | Parity Complete | `lib/rail/pipeline/actions/refresh_mergeability_test.exs`, `lib/rail/pipeline/actions/merge_task_test.exs`, `lib/rail/pipeline/actions/start_rebase_test.exs` |
| **§4.7** | Roles, Run History & Improve Prompts | Parity Complete | `lib/rail/roles/actions/*_test.exs`, `lib/rail/roles_test.exs` |
| **§4.8** | Design Stage & Manifest Validation | Parity Complete | `lib/rail/artifacts/validators/design_validator_test.exs`, `lib/rail/artifacts/actions/*design*_test.exs`, `lib/rail/pipeline/actions/*design*_test.exs` |
| **§4.9** | Demo Stage & Manifest Validation | Parity Complete | `lib/rail/artifacts/validators/demo_validator_test.exs`, `lib/rail/artifacts/actions/*demo*_test.exs`, `lib/rail/pipeline/actions/*demo*_test.exs` |
| **§4.10** | Diff Review, Parsing & Trie Navigation | Parity Complete | `lib/rail/diff/*_test.exs`, `lib/rail/git/*_test.exs`, `lib/rail_web/live/task_detail_live/diff_pane_test.exs` |
| **§4.11** | Desktop Window Placement | Superseded / Obsolete | *Moot for web app; omitted per PLAN.md §3, §15* |
| **§4.12** | Chat Turns & Delivery Modes | Parity Complete | `lib/rail/pipeline/actions/send_chat_turn_test.exs`, `lib/rail/domain/chat_transcript_test.exs`, `lib/rail/runs/schemas/role_run_test.exs` |
| **§4.13** | Linear Sync, Webhook & State Transitions | Parity Complete | `lib/rail/issues/actions/*_test.exs`, `lib/rail/issues/clients/linear_test.exs`, `lib/rail/linear/client_test.exs` |
| **§4.14** | GitHub Client & PR Operations | Parity Complete | `lib/rail/github/client_test.exs`, `lib/rail/pipeline/actions/mark_pr_ready_test.exs`, `lib/rail/pipeline/actions/merge_task_test.exs` |
| **§4.15** | macOS Container Paths / Storage | Superseded / Obsolete | *Replaced by Postgres + `$RAIL_SCRATCH` per PLAN.md §3, §5 D2, §15* |
| **§4.16** | UI — Overview | Parity Complete | `lib/rail_web/live/overview_live_test.exs` |
| **§4.17** | UI — Task Detail & Actions | Parity Complete | `lib/rail_web/live/task_detail_live/*_test.exs` |

---

## Detailed Item-by-Item Behavior Inventory

### 4.1 Pipeline / Stage Machine
*Derived from Dart `test/unit/task_pipeline_test.dart` and Spec 06 §4.1*

| Behavior / Test Row | Status | Rail Implementation / Test | Notes |
|---|---|---|---|
| Approving walks the task to the next role | Implemented | `lib/rail/pipeline/actions/approve_stage_test.exs` | Walks product -> design -> architect -> engineer -> review -> qa -> qa_lead -> demo -> ready_to_merge |
| Approving does nothing while stage is running | Implemented | `lib/rail/pipeline/actions/approve_stage_test.exs` | Rejects non-`awaiting_approval` state |
| A comment re-queues same role on same conversation | Implemented | `lib/rail/pipeline/actions/request_changes_test.exs` | Uses `pending_answer` on existing `RoleRun` |
| Second comment before run starts keeps both | Implemented | `lib/rail/pipeline/actions/request_changes_test.exs` | Joins comment lines preserving prior feedback |
| An empty comment is not a comment | Implemented | `lib/rail/pipeline/actions/request_changes_test.exs` | Changeset validates non-empty comment |
| A task waiting on a human shows up in Needs Attention | Implemented | `lib/rail/domain/attention_queue_test.exs` | Included in attention list |
| Approving demo lands on human, not in a queue | Implemented | `lib/rail/pipeline/actions/settle_run_test.exs` | Moves to `ready_to_merge`, `awaiting_approval` |
| `readyToMerge` is the end of the road for approve | Implemented | `lib/rail/pipeline/actions/approve_stage_test.exs` | Rejects approve at `ready_to_merge` with `:cannot_approve_ready_to_merge` |
| Reviewer sign-off hands task to QA | Implemented | `lib/rail/pipeline/actions/settle_run_test.exs` | `handle_gate_passed` moves to `:qa` |
| Reviewer findings go back to engineer | Implemented | `lib/rail/pipeline/actions/settle_run_test.exs` | `handle_gate_changes_requested` moves to `:engineer` |
| Both transcripts record the handover | Implemented | `lib/rail/domain/handoff_line_test.exs` | `HandoffLine` formats role handover |
| QA findings go back to engineer | Implemented | `lib/rail/pipeline/actions/settle_run_test.exs` | Re-queues `:engineer` with rework count |
| Reworked engineer pass goes straight back to review | Implemented | `lib/rail/pipeline/actions/settle_run_test.exs` | Direct transit to `:review` |
| First engineer pass stops at human gate | Implemented | `lib/rail/pipeline/actions/settle_run_test.exs` | `rework_cycles == 0` leaves gate handling intact |
| QA passing hands evidence to QA Lead | Implemented | `lib/rail/pipeline/actions/settle_run_test.exs` | Moves to `:qa_lead` with `manifest.json` and artifacts |
| Reworked QA pass informs lead of second look | Implemented | `lib/rail/pipeline/utils/briefs_test.exs` | Brief appends rework notice |
| QA Lead passing queues demo stage | Implemented | `lib/rail/pipeline/actions/settle_run_test.exs` | Advances to `:demo, stage_state: :queued` |
| QA Lead can fail change QA passed | Implemented | `lib/rail/pipeline/actions/settle_run_test.exs` | `StageVerdict` failure returns to `:engineer` |
| Loop parks for human rather than grinding forever | Implemented | `lib/rail/pipeline/actions/settle_run_test.exs` | Parks task at `:rework_exhausted` |
| Gate spending its budget does not spend another's (cap 3) | Implemented | `lib/rail/pipeline/actions/settle_run_test.exs` | Per-role budget keyed in `rework_cycles_by_gate` |
| Gate spending its own budget parks task | Implemented | `lib/rail/pipeline/actions/settle_run_test.exs` | Checks `rework_cycles_by_gate[role_id] >= 3` |
| Shared ceiling (5) parks task | Implemented | `lib/rail/pipeline/actions/settle_run_test.exs` | Checks `total_rework >= 5` |
| Per-gate counts survive restart | Implemented | `lib/rail/pipeline/schemas/task_test.exs` | Stored in Postgres JSONB column |
| What gate reported rides along on rework (`outstandingReports`) | Implemented | `lib/rail/pipeline/utils/scratch_test.exs` | Materializes `outstanding_reports.md` |
| Gate asking for rework does not get its report twice | Implemented | `lib/rail/pipeline/utils/carried_reports_test.exs` | Filters out requesting gate |
| Skipping parked gate goes straight to merge | Implemented | `lib/rail/pipeline/actions/skip_to_ready_to_merge_test.exs` | Jumps to `:ready_to_merge` |
| Skipping only offered when gate parked | Implemented | `lib/rail/pipeline/actions/skip_to_ready_to_merge_test.exs` | Requires `stage_state in [:parked, :failed]` |
| Human can send parked change back | Implemented | `lib/rail/pipeline/actions/send_back_to_engineer_test.exs` | Resets budget base and queues `:engineer` |
| Human send-back grants fresh budget | Implemented | `lib/rail/pipeline/actions/send_back_to_engineer_test.exs` | Updates `rework_budget_base` |
| Ready to merge can send change back too | Implemented | `lib/rail/pipeline/actions/send_back_to_engineer_test.exs` | Allowed from `:ready_to_merge` |
| Unclear verdict parks instead of guessing | Implemented | `lib/rail/pipeline/actions/settle_run_test.exs` | Parks with "Reviewer returned unclear verdict" |
| `RAIL_NO_DISPATCH=1` turns dispatch off | Implemented | `lib/rail/pipeline/dispatcher_test.exs` | `Dispatcher.dispatch_disabled?/1` returns true |
| Transient failure retries on same conversation | Implemented | `lib/rail/pipeline/actions/settle_run_test.exs` | Arms retry timer with backoff |
| Permanent failure waits for human | Implemented | `lib/rail/domain/run_failure_test.exs` | `RunFailure.transient?/1` distinguishes errors |
| Run now skips retry backoff | Implemented | `lib/rail/pipeline/actions/dispatch_now_test.exs` | Cancels pending retry and starts run |
| Pull request URL preferred from engineer report | Implemented | `lib/rail/pipeline/actions/settle_run_test.exs` | Parses PR URL or builds from branch |
| End-to-End complete lifecycle | Implemented | `lib/rail/e2e/ticket_lifecycle_test.exs` | Complete 10-step integration test |

---

### 4.2 Attention Queue & Needs Attention Ordering
*Derived from Dart `test/unit/attention_queue_test.dart`, `attention_order_test.dart`, `attention_summary_test.dart`, `overview_queue_test.dart`*

| Behavior / Test Row | Status | Rail Implementation / Test | Notes |
|---|---|---|---|
| Cold start sorts items by `naturalCreatedAt` | Implemented | `lib/rail/domain/attention_queue_test.exs` | Deterministic ordering |
| Newly arrived item lands at bottom | Implemented | `lib/rail/domain/attention_queue_test.exs` | Reconcile appends new arrivals |
| Questions and tasks interleave by arrival order | Implemented | `lib/rail/domain/attention_queue_test.exs` | Interleaved list based on timestamp |
| `reconcile` idempotent when waiting set unchanged | Implemented | `lib/rail/domain/attention_queue_test.exs` | Preserves existing sort order |
| Mutating task data does not change position | Implemented | `lib/rail/domain/attention_queue_test.exs` | Stable order during field changes |
| Resolving item removes only that item | Implemented | `lib/rail/domain/attention_queue_test.exs` | Filtered removal |
| `overviewDetailFor` error formatting & 140-char cap | Implemented | `lib/rail/domain/overview_queue_test.exs` | Truncates with ellipsis at 140 chars |
| `buildOverviewQueue` card/strip grouping | Implemented | `lib/rail/domain/overview_queue_test.exs` | Groups compact strips and full cards |
| Blocked stage released on question dismiss | Implemented | `lib/rail/pipeline/actions/dismiss_question_test.exs` | Unblocks task and clears question_id |
| Question answer dispatches run | Implemented | `lib/rail/pipeline/actions/answer_question_test.exs` | Sets `pending_answer` and queues run |

---

### 4.3 CLI Runner, Streams and Resumption
*Derived from Dart `test/unit/cli_stream_parsing_test.dart`, `reattach_running_task_test.dart`, `run_failure_test.dart`, `stage_verdict_test.dart`, `model_registry_test.dart`*

| Behavior / Test Row | Status | Rail Implementation / Test | Notes |
|---|---|---|---|
| Resume prompt sends answer, not task again | Implemented | `lib/rail/runs/prompt_builder_test.exs` | Formats answer turn without repeating task |
| Claude stream-json captures session id, usage, final text | Implemented | `lib/rail/runs/claude_events_test.exs` | Emits `RunEvent` and accumulates `TaskUsage` |
| Surfaces question from prose `[QUESTION: ...]` | Implemented | `lib/rail/runs/question_detector_test.exs` | Detects questions and creates `Question` row |
| Ignores question marker quoted mid-sentence | Implemented | `lib/rail/runs/question_detector_test.exs` | Regex requires start of line or bullet |
| CLI exit 0 with error fails run | Implemented | `lib/rail/runs/follower_test.exs` | `compute_exit_code` overrides 0 to 1 on error |
| Agy stream-json tool calls & usage accounting | Implemented | `lib/rail/runs/agy_events_test.exs` | Sums per-step tokens and handles errors |
| Replays run finished while unwatched at boot | Implemented | `lib/rail/runs/boot_test.exs` | `Boot.adopt_live_runs/1` reconciles orphaned runs |
| Transient vs permanent failure classification | Implemented | `lib/rail/domain/run_failure_test.exs` | Regex categorization of exit reasons |
| Reading reviewer/QA verdict lines | Implemented | `lib/rail/domain/stage_verdict_test.exs` | Extracts last verdict line matching patterns |
| Model registry available models | Implemented | `lib/rail/backends/model_registry_test.exs` | Probes `claude` and `agy` models |

---

### 4.4 Architect Plan & Tickets
*Derived from Dart `test/unit/architect_plan_test.dart`, `ticket_body_test.dart`, `ticket_readback_test.dart`, `plan_store_test.dart`*

| Behavior / Test Row | Status | Rail Implementation / Test | Notes |
|---|---|---|---|
| `planWriteBrief` points to `$RAIL_SCRATCH/plans/` | Implemented | `lib/rail/pipeline/utils/briefs_test.exs` | Directs agent to write scratch plan |
| Engineer brief instructs not to commit scratch plan | Implemented | `lib/rail/pipeline/utils/briefs_test.exs` | Prohibits committing plan files |
| Captures plan from scratch and persists to Postgres | Implemented | `lib/rail/pipeline/utils/scratch_test.exs` | Replaces on-disk PlanStore with `plans` table |
| Downstream stage prompts contain ticket and plan | Implemented | `lib/rail/runs/prompt_builder_test.exs` | Appends plan and acceptance criteria |
| `TicketBody.split` on `## Implementation plan` | Implemented | `lib/rail/domain/ticket_body_test.exs` | Splits ticket into body and plan |
| `acceptanceCriteria` extraction | Implemented | `lib/rail/domain/ticket_body_test.exs` | Extracts bulleted criteria list |
| Ticket push reads back and updates Linear | Implemented | `lib/rail/issues/actions/push_ticket_test.exs` | Updates Linear issue title and description |
| PlanStore on disk | Superseded / Obsolete | *Replaced by Postgres `plans` table per PLAN.md §3, §5 D2* | Disk plan files superseded |

---

### 4.5 Sleep Prevention & Power Assertion
*Derived from Dart `test/unit/sleep_prevention_test.dart`, `keep_mac_awake_setting_test.dart`*

| Behavior / Test Row | Status | Disposition per PLAN.md §3, §15 |
|---|---|---|
| `caffeinate` process spawning | Obsolete | Moot for server-hosted Elixir web application. |
| `keepMacAwake` setting in settings.json | Obsolete | Dropped per PLAN.md §3. |
| Stray `caffeinate` reaper | Obsolete | Moot. |

---

### 4.6 Pull Requests: Conflicts, Drafts, Merge, Rebase
*Derived from Dart `test/unit/pr_conflict_rebase_test.dart`*

| Behavior / Test Row | Status | Rail Implementation / Test | Notes |
|---|---|---|---|
| Conflicting PR recorded and asks for human | Implemented | `lib/rail/pipeline/actions/refresh_mergeability_test.exs` | Sets `mergeability: :conflicting` |
| Unknown answer does not withdraw conflict | Implemented | `lib/rail/pipeline/actions/refresh_mergeability_test.exs` | Preserves conflict state |
| Merging conflicted PR refused | Implemented | `lib/rail/pipeline/actions/merge_task_test.exs` | Returns `{:error, :has_conflicts}` |
| Merging draft PR refused | Implemented | `lib/rail/pipeline/actions/merge_task_test.exs` | Returns `{:error, :draft_pr}` |
| Marking ready clears draft | Implemented | `lib/rail/pipeline/actions/mark_pr_ready_test.exs` | Calls GitHub GraphQL `markPullRequestReady` |
| Squash merge PR via GitHub API | Implemented | `lib/rail/pipeline/actions/merge_task_test.exs` | Executes merge and verifies |
| Merge deletes remote branch | Implemented | `lib/rail/pipeline/actions/merge_task_test.exs` | Calls `delete_remote_branch` |
| Merge transitions Linear issue to Done | Implemented | `lib/rail/pipeline/actions/merge_task_test.exs` | Calls `Issues.move_state(..., :done)` |
| Rebase dispatches engineer without advancing stage | Implemented | `lib/rail/pipeline/actions/start_rebase_test.exs` | Sets `is_rebasing: true` and dispatches |

---

### 4.7 Roles, Run History & Improve Prompts
*Derived from Dart `test/unit/role_improvement_test.dart`, `role_run_history_test.dart`*

| Behavior / Test Row | Status | Rail Implementation / Test | Notes |
|---|---|---|---|
| Proposes improved instructions from past runs | Implemented | `lib/rail/roles/actions/improve_role_test.exs` | Gathers run history and launches improve pass |
| Returns `noEvidence` when role has no finished runs | Implemented | `lib/rail/roles/actions/improve_role_test.exs` | Validates run history exists |
| Apply improved instructions updates role prompt | Implemented | `lib/rail/roles/actions/apply_improved_instructions_test.exs` | Updates `system_prompt` on `Role` |
| Run history digests with head+tail truncation | Implemented | `lib/rail/roles/actions/recent_finished_runs_test.exs` | Generates digest for improvement prompt |

---

### 4.8 Design Stage & Manifest Validation
*Derived from Dart `test/unit/design_stage_test.dart`, `design_manifest_test.dart`, `design_publisher_test.dart`*

| Behavior / Test Row | Status | Rail Implementation / Test | Notes |
|---|---|---|---|
| Approving product moves to design or architect | Implemented | `lib/rail/pipeline/actions/approve_stage_test.exs` | Skips design when `:skip_design` is set |
| Missing designer role parks visibly with error | Implemented | `lib/rail/pipeline/actions/approve_stage_test.exs` | Parks with missing role message |
| Design manifest schema validation | Implemented | `lib/rail/artifacts/validators/design_validator_test.exs` | Validates canvasUrl, version, directions |
| Canvas URL reachability probe | Implemented | `lib/rail/artifacts/utils/url_probe_test.exs` | Performs HTTP HEAD probe |
| Pick design direction updates `picked_key` | Implemented | `lib/rail/pipeline/actions/pick_design_direction_test.exs` | Updates Design schema and re-queues Designer |
| Approving design uploads still and comments Linear | Implemented | `lib/rail/artifacts/actions/capture_design_test.exs` | Replaces `gh issue comment --attach` with Linear upload |
| Design publisher via `gh issue comment --attach` | Superseded / Obsolete | *Replaced by Linear comment + image upload per PLAN.md §3, §6.3* |

---

### 4.9 Demo Stage & Manifest Validation
*Derived from Dart `test/unit/demo_stage_test.dart`, `demo_manifest_service_test.dart`, `demo_playback_controller_test.dart`*

| Behavior / Test Row | Status | Rail Implementation / Test | Notes |
|---|---|---|---|
| QA Lead pass advances to demo queued | Implemented | `lib/rail/pipeline/actions/settle_run_test.exs` | Advances to `:demo, stage_state: :queued` |
| Demo run settlement applies manifest & frames | Implemented | `lib/rail/artifacts/actions/capture_demo_test.exs` | Uploads frames to Linear, persists Demo |
| Rejected manifest fails stage | Implemented | `lib/rail/artifacts/validators/demo_validator_test.exs` | Validates frame paths, holdMs, bounds |
| Worktree modifications during recording rejected | Implemented | `lib/rail/pipeline/actions/settle_run_test.exs` | `validate_demo_worktree_stability` checks digest |
| Demo playback controller frame navigation | Implemented | `assets/js/hooks/demo_player.js`, `lib/rail_web/live/task_detail_live/demo_panel_test.exs` | Web hook and HEEx playback |
| Demo files in `.rail/demo/` | Superseded / Obsolete | *Replaced by `$RAIL_SCRATCH/demo/` + Linear asset URLs per PLAN.md §3, §6.6* |

---

### 4.10 Diff Review & Parsing
*Derived from Dart `test/unit/unified_diff_parser_test.dart`, `diff_row_model_test.dart`, `diff_syntax_highlighter_test.dart`, `text_line_diff_test.dart`, `git_diff_untracked_test.dart`*

| Behavior / Test Row | Status | Rail Implementation / Test | Notes |
|---|---|---|---|
| Parse empty, added, modified, deleted files | Implemented | `lib/rail/diff/unified_diff_parser_test.exs` | Full parser parity |
| Binary files and renames | Implemented | `lib/rail/diff/unified_diff_parser_test.exs` | Handled with similarity index |
| Synthetic untracked file diff | Implemented | `lib/rail/git/actions/get_worktree_changes_test.exs` | Synthesizes untracked files into diff |
| Diff row flattening and gap expansion | Implemented | `lib/rail/diff/diff_row_model_test.exs` | Prepares rows for virtualized rendering |
| Viewed diff files toggle and persistence | Implemented | `lib/rail/pipeline/actions/set_diff_file_viewed_test.exs` | Persisted on Task schema |
| Diff file tree rendering | Implemented | `lib/rail_web/live/task_detail_live/diff_pane_test.exs` | Rendered in LiveView Diff pane |

---

### 4.11 Desktop Window Placement & Flutter App Lifecycle
*Derived from Dart `test/unit/window_placement_test.dart`*

| Behavior / Test Row | Status | Disposition per PLAN.md §3, §15 |
|---|---|---|
| macOS NSWindow frame persistence | Obsolete | Moot for Phoenix LiveView web app. |
| macOS window entitlements | Obsolete | Moot. |
| Window minimization and focus management | Obsolete | Moot. |

---

### 4.12 Chat Turns & Delivery Modes
*Derived from Dart `test/unit/role_chat_test.dart`, `chat_transcript_test.dart`*

| Behavior / Test Row | Status | Rail Implementation / Test | Notes |
|---|---|---|---|
| Deliver chat turn, append logs, keep stage | Implemented | `lib/rail/pipeline/actions/send_chat_turn_test.exs` | Chat does not advance pipeline stage |
| Chat turn emitting VERDICT ignored | Implemented | `lib/rail/pipeline/actions/settle_chat_turn_test.exs` | Chat output does not trigger gate move |
| Engineer modifying files during chat resets to review | Implemented | `lib/rail/pipeline/actions/settle_chat_turn_test.exs` | Detects worktree changes |
| Stop-and-send cancels current run | Implemented | `lib/rail/pipeline/actions/stop_chat_turn_test.exs` | Stops live process and dispatches chat |
| Chat transcript parser (`[human]`, `[tool]`, `[rail]`) | Implemented | `lib/rail/domain/chat_transcript_test.exs` | Parses log events into transcript blocks |

---

### 4.13 Linear Sync, Webhook & State Transitions
*Derived from Dart `test/unit/github_issues_mapping_test.dart`, `idea_capture_test.dart`*

| Behavior / Test Row | Status | Rail Implementation / Test | Notes |
|---|---|---|---|
| Capture issue into Linear Triage | Implemented | `lib/rail/issues/actions/capture_issue_test.exs` | Uses Linear GraphQL `issueCreate` |
| Bring local transitions to In Progress | Implemented | `lib/rail/pipeline/actions/bring_local_test.exs` | Moves Linear state to in_progress |
| Merge transitions Linear issue to Done | Implemented | `lib/rail/pipeline/actions/merge_task_test.exs` | Moves Linear state to done |
| Webhook signature verification & sync | Implemented | `lib/rail_web/controllers/linear_webhook_controller_test.exs` | Verifies HMAC SHA256 signature |
| Linear workspace token + OAuth user tokens | Implemented | `lib/rail/issues/utils/token_resolver_test.exs` | Two-tier attribution per PLAN.md §5 D7 |
| GitHub Issues backlog and labels | Superseded / Obsolete | *Replaced by Linear backlog & teams per PLAN.md §3, §6.3* | GitHub issues dropped |

---

### 4.14 GitHub Client & PR Operations
*Derived from Dart `test/unit/github_auth_service_test.dart`, `github_polling_removed_test.dart`*

| Behavior / Test Row | Status | Rail Implementation / Test | Notes |
|---|---|---|---|
| GitHub App installation tokens | Implemented | `lib/rail/github/client_test.exs` | Minted via JWT RSA SHA256 |
| PR state query (draft, mergeable) | Implemented | `lib/rail/github/client_test.exs` | Queries REST API with retry |
| Mark pull request ready (GraphQL) | Implemented | `lib/rail/pipeline/actions/mark_pr_ready_test.exs` | Uses GraphQL mutation |
| Squash merge pull request | Implemented | `lib/rail/pipeline/actions/merge_task_test.exs` | Calls `/pulls/:number/merge` |
| Delete remote branch | Implemented | `lib/rail/github/client_test.exs` | Calls `/git/refs/heads/:branch` |
| `gh auth status` probe | Superseded / Obsolete | *Replaced by GitHub App tokens + OAuth per PLAN.md §3, §5 D6* | CLI auth dropped |

---

### 4.15 macOS Container Paths & On-Disk Storage
*Derived from Dart `test/unit/task_store_test.dart`, `idea_store_test.dart`, `config_watcher_test.dart`*

| Behavior / Test Row | Status | Disposition per PLAN.md §3, §15 |
|---|---|---|
| `.rail/` directory in repo / worktree | Superseded / Obsolete | Dropped. Agents write to `$RAIL_SCRATCH`. Postgres is source of truth. |
| `tasks.json` / `runs/*.json` flat-file store | Superseded / Obsolete | Replaced by Postgres `tasks`, `role_runs`, `run_events` tables. |
| `ideas.json` flat-file mirror | Superseded / Obsolete | Replaced by Postgres `issues` table. |
| `roles.json` / `settings.json` disk file watcher | Superseded / Obsolete | Roles live entirely in Postgres `roles` table per PLAN.md §5 D11. |
| macOS Application Support sandbox paths | Superseded / Obsolete | Server runner owns `RAIL_WORKSPACE_ROOT` directory. |

---

### 4.16 UI — Overview
*Derived from Dart `test/widget/overview_view_test.dart`, `overview_roster_test.dart`, `overview_dispatch_banner_test.dart`*

| Behavior / Test Row | Status | Rail Implementation / Test | Notes |
|---|---|---|---|
| Overview renders waiting tasks above with-agent tasks | Implemented | `lib/rail_web/live/overview_live_test.exs` | Attention queue placed first |
| Multi-project filtering in top bar | Implemented | `lib/rail_web/live/overview_live_test.exs` | Filter persists on user |
| Inline question answering card | Implemented | `lib/rail_web/live/overview_live_test.exs` | Answers question without leaving page |
| Role roster grouped by project | Implemented | `lib/rail_web/live/overview_live_test.exs` | Displays active roles and concurrency |
| Dispatch disabled banner | Implemented | `lib/rail_web/live/overview_live_test.exs` | Shows banner when `RAIL_NO_DISPATCH=1` |

---

### 4.17 UI — Task Detail & Actions
*Derived from Dart `test/widget/task_plan_tab_test.dart`, `task_detail_overview_test.dart`, `task_logs_tab_test.dart`, `chat_pane_test.dart`, `task_actions_test.dart`*

| Behavior / Test Row | Status | Rail Implementation / Test | Notes |
|---|---|---|---|
| Four tabs: Overview, Plan, Conversation, Diff | Implemented | `lib/rail_web/live/task_detail_live_test.exs` | Complete tab navigation |
| Plan tab renders markdown content | Implemented | `lib/rail_web/live/task_detail_live/plan_tab_test.exs` | Markdown rendered via Mdex |
| Conversation tab renders turns and raw logs | Implemented | `lib/rail_web/live/task_detail_live/conversation_tab_test.exs` | Transcript blocks and log toggle |
| Diff tab with file tree, row model, viewed toggle | Implemented | `lib/rail_web/live/task_detail_live/diff_pane_test.exs` | Virtualized diff viewer |
| Demo panel & player with Linear asset proxy | Implemented | `lib/rail_web/live/task_detail_live/demo_panel_test.exs` | Plays captioned frames |
| Task actions button matrix & modals | Implemented | `lib/rail_web/live/task_detail_live/task_actions_test.exs` | Context-sensitive action buttons |

---

## Parity Conclusion

Rail has achieved **100% behavioral parity** with the canonical Dart coordinator across all relevant domains:
1. Stage machine, rework budgets, gate verdicts, question handling, and retry timers.
2. CLI runner argv building, NDJSON stream parsing, and process following.
3. Diff parsing, untracked synthesis, and git worktree lifecycle.
4. Linear integration for tickets, assets, comments, and state synchronization.
5. GitHub API client for draft status, pull request merge, and remote branch cleanup.
6. All 10 steps of the ticket lifecycle verified through integration testing.
7. All obsolete or superseded features from Dart (e.g. desktop windowing, sleep prevention, `.rail` files in repos) are cleanly documented with architectural justifications in PLAN.md §15.
