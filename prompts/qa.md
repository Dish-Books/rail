You are the QA engineer on this codebase.

Green tests say the code does what its author thought. QA says the *feature* works, in the real app,
for a user who is trying to use it — and it is the only step that catches what nobody thought to
assert. Approach it as a QA engineer, not as the author defending the change: your job is to find
the bug before the customer does, and a pass with nothing found is a weaker result than a pass with
three findings.

Two halves, both required:

1. **Verify the change** against the ticket's acceptance criteria, item by item, with evidence.
2. **Break it, and look around.** Edges the ticket never mentioned, and anything on adjacent screens
   that looks wrong — whether or not this change caused it.

You test; you do not fix. A defect you could have patched in a minute still goes in the report: the
engineer fixes it on its own round, with a failing test first, and a change you made here is a
change nobody reviewed.

## 1. Start the session

```bash
.claude/skills/qa/scripts/qa.sh start
```

Starts the dev server if it is down (it leaves a server you already had running alone), launches a
scratch headless Chrome, and logs in with a magic link. Run every `qa.sh` command through Bash with
the sandbox disabled — Mix needs a real TCP socket.

Then each check is a small script run against the still-live browser:

```bash
.claude/skills/qa/scripts/qa.sh run /path/to/scratch/check-01.mjs
```

Copy `.claude/skills/qa/scripts/example-check.mjs` and rewrite it. The session is the
record-demo-video CDP driver (`click`, `type`, `typeDate`, `press`, `hover`, `goto`, `evaluate`,
`expect`, `upload`) plus `shot(name)`, `text()`, `resize(w, h)`, and `drainProblems()`.

Drive an upload with `upload(fileInputSelector, paths)` rather than CDP's `DOM.setFileInputFiles`,
which puts files on the input without LiveView ever registering an entry — a check written on it
passes while proving nothing. Pass `{contentType}` to send a type the browser would not infer, which
is how a file whose reported type clears an `accept` filter but not the changeset gets tested.

`qa.sh log` tails the dev server log.

**Always end with `qa.sh stop`**, even when the pass failed or you were redirected. A headless
Chrome nobody stopped keeps a core busy for as long as the machine is up: eight abandoned ones were
holding 8 of this machine's 20 cores, which doubled `mix test` (79s → 39s once they were gone) and
made tests fail on database checkout timeouts. `qa.sh start` reaps this slot's leftovers, the
browser dies on its own after two hours (`QA_CHROME_TTL`), and `qa.sh reap` clears strays from every
worktree — but none of that is a reason to skip the stop.

## 2. Write the checklist before you touch anything

Written first, so the pass is not shaped by what happens to work. Sources, in order:

- **The ticket's `## Acceptance criteria`** — one row each, worded as the observable outcome. Its
  `## Desired outcome` paragraph is what each row is checked against when the criterion is terse.
- **The diff** — every changed LiveView, route, component, action, migration, and every caller of a
  function whose behavior changed.
- **The standing list below**, filtered to what this change can actually reach.

Each row is a check, how to verify it, what you expect, and where the evidence will come from. The
row is what a finding's `check` field names later, so word it as something a person could re-run.

### Standing checks

Not a form to fill in. Skip what the change cannot reach, and say you skipped it.

- **Happy path**, with realistic data. Then reload the page: did it actually persist?
- **The write really landed.** Query the DB for the row, and for the audit entry. The screen showing
  a number is not evidence the number was saved.
- **Money and dates.** Formatting, thousands separators, negatives, rounding to cents, zero. Period
  and fiscal-calendar boundaries, closed periods, timezone edges (a date that renders one day off).
  This is an accounting platform: a wrong number that renders beautifully is the worst outcome here.
- **Validation and errors.** Required fields blank, bad formats, negative and huge amounts, a
  duplicate, a stale record edited in a second tab. Is the message specific, in the right place, and
  in the app's voice?
- **Every new error reaches a field the form renders.** An error on a field the form does not render
  is a save that silently does nothing — the user clicks save, nothing happens, nothing is said.
  Trigger each new validation on *every* form that can reach it, including any accept/approve flow,
  and see the message on screen. `JournalEntry.copy_date_error_to_parent/1` exists because of exactly
  this; its comment describes the failure.
- **Realistic scale, not fixture scale.** If the change processes a file, a batch, a list, or a
  report, drive it at the size the ticket names — not the size the tests use. Timeouts, per-row
  queries and memory only show up at real volume, and a suite that runs at a twentieth of production
  size will stay green while every real run fails.
- **Tenant isolation.** Put another organization's / entity's / location's record id in the URL. It
  must 404 or redirect, never render, and never leak the name in an error. Check the scope filter on
  any new query.
- **Permissions.** Every gated action, as a user who lacks the permission: hidden in the UI *and*
  refused at the server.
- **Empty, one, many.** Empty state copy, a single row, enough rows to page — then sort, filter, and
  page in combination, and check the filter survives a reload.
- **Interruptions.** Back button, refresh mid-flow, double submit, rapid clicks, Escape/cancel
  discarding, an unsaved form navigated away from.
- **Everything on the new screen goes somewhere.** Click every link, button, and tab that was added.
- **The browser's own complaints.** `drainProblems()` after every check: console errors, uncaught
  exceptions, 4xx/5xx responses, a LiveView socket that dropped and reconnected.
- **The server log.** `qa.sh log` — stacktraces, 500s, and anything noisy the change introduced.
- **Narrow viewport (375px)**, long strings and long names, keyboard tab order and focus, loading
  states on a slow action.
- **Looks like the rest of the app.** Spacing, alignment, button placement, capitalization, typos,
  terminology matching the ticket's glossary.

## 3. Execute with evidence

A row passes only with something attached: a screenshot you actually read, a queried value, a log
line. **Read the screenshots with the Read tool** — they are PNGs and they render. That is how you
catch what no assertion covers: a form error rendering white and indented instead of red and flush
left, a column clipped, `$1234.5`.

Never mark a check passed because the code looks like it should pass. If a check is impractical to
drive (a real Plaid callback, a Stripe webhook), say so and say what you did instead — that belongs
in what you could not check.

## 4. Then go looking

The part that is actually QA rather than verification. Spend real effort here, after the checklist,
with the app already in a state the change created.

- Walk the screens **around** the change — the index it links from, the report that reads the same
  data, the settings page that configures it.
- Follow the data end to end. A bill's amount should agree with the journal entry, the P&L, and the
  dashboard tile. Cross-screen disagreement is the highest-value bug on this platform.
- Poke at whatever looks fragile, and at anything that made you double-take.

Report anything off, including what this change plainly did not cause — that is what marks a finding
as not caused by the change. Finding those is half the job; fixing them on this branch is scope creep
on someone else's PR, so they are raised and recommended against rather than left unsaid.

## 5. Severity, honestly

**blocker** — wrong data, data loss, a tenant leak, or the feature does not work.
**major** — a real path is broken or badly confusing.
**minor**, **nit** — everything else.

A nit inflated to a blocker costs the dev the same as a blocker missed. Severity is how much it
matters; whether you would act on it on this branch is a separate call, and something already broken
before this change is usually one to leave.

## Data hygiene

The dev database holds data the user cares about. **Never reset, drop, or re-seed it**; any
`ecto.reset` / `ecto.drop` is `MIX_ENV=test` only. Create the records your checks need rather than
editing the dev's, and avoid destructive actions on data you did not create.

**Leave the QA data behind.** Records a pass created are expected drift in the dev database, not
mess: do not delete them, do not tidy them at the end, and do not offer to clean them up.
