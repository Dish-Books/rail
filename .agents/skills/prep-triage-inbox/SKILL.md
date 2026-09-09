---
name: prep-triage-inbox
description: Fills the Linear Triage queue with researched tickets, unattended. Use for the 5am weekday run, to catch up a day it was missed, or when the user asks to sweep Slack for anything that should be a ticket.
---

# Prep Triage Inbox

The unattended half of the daily pass: Slack → researched Linear tickets sitting in **Triage**, waiting for the lead to review them in Linear.

The lead then either moves a ticket to Ready for Dev, or answers its open questions in a comment. [triage-inbox](../triage-inbox/SKILL.md) picks those comments up and finishes the job.

**This runs in the cloud, on a throwaway checkout.** The repository is checked out fresh, so the docs and code this skill reads are all present, but nothing may be left on local disk and nothing may be read from a previous run's disk. Linear is the only durable output.

## Operating constraint (read first)

This skill writes exactly four things:

1. **Linear tickets, in `Triage` and nowhere else.**
2. **Linear comments on those tickets** — one per open question, assumption, or proposed split.
3. **The pending Slack replies document** — appended to, never sent from.
4. **The `Triage watermark` document.**

It never posts to Slack, never moves a ticket past `Triage`, never touches code or git, and never opens a PR. It does not create sub-issues, even where it proposes a split. If you are about to write anywhere else, stop.

**Nobody sees this run before it finishes.** There is no batch to approve and no human in the loop, which is exactly why the boundaries above are absolute. A ticket created here is recoverable in seconds by closing it in Linear; a Slack message sent to a customer at 5am is not.

## 1. Establish the window

Read the Linear document `Triage watermark`, ID `357434d3-056d-4c1c-9cd4-34f98c01c41a`, with `get_document`. It holds a fenced JSON block recording the newest Slack message already processed **per channel**:

```json
{
  "slack": { "C0B2EGYV61J": "1754586000.123456", "C09DM4L73ND": "1754521200.000200" }
}
```

Read **from the watermark forward**. That is what makes a skipped day safe: if yesterday's run never happened, the watermark never moved, and this run covers both days in one pass.

- **No watermark** (first run, or the JSON block is `{}`): fall back to the start of the previous business day. Running Monday means from Friday 00:00. Say so in the run summary.

## 2. Gather from Slack

Read `#customer-support` (`C0B2EGYV61J`, public) and `#product` (`C09DM4L73ND`, **private**). Any channel lookup must pass `channel_types: "public_channel,private_channel"` or `#product` silently will not resolve.

Use `slack_read_channel` with `oldest` set to the channel's watermark. For every candidate message, pull the **whole thread** with `slack_read_thread` before deciding anything. The parent message is frequently not the whole ask.

Keep only genuine requests, bug reports, and feature asks. Drop:

- Chatter, thanks, acknowledgements, scheduling.
- Replies on a thread that is already ticketed.
- Questions that someone answered in the thread. If the thread resolved itself, there is nothing to build.
- **Threads waiting on an answer.** See below.
- **Tasks.** See below.

Record what you skipped and why, one line per skipped thread, in the run summary. Silent filtering is how requests get lost.

### A thread waiting on an answer is not a ticket

Where the last word in the thread is a question to the reporter — ours or a teammate's — and nobody has answered it, **the ask is not settled**. Writing a ticket now puts a guess in the queue, and the answer routinely changes what the ask even is.

**Skip it. Name it in the run summary**, one line: the channel, the thread link, and what it is waiting on. No ticket, no comment, no queued reply, and do not ask the question again in Slack. It re-enters the window on its own when someone answers.

This is not the same as an ambiguity you can close yourself (step 5): that is your question about a settled ask. This is an ask that is still incomplete.

### A task is not a ticket

Plenty of requests are asking for something to be **done**, not for the product to **change**: apply this discount to this customer, correct this record, flip this setting, re-run this import.

**Do not open a ticket for one.** A ticket that cannot be implemented clogs the queue, gets estimated and prioritized against real work.

The test: **would this be finished by a person doing it, or by a change shipping?** If a person doing it once finishes the job, it is a task.

Where it genuinely needs both — the record fixed now *and* the product changed so nobody has to fix it by hand again — those are two different things. The task is the reporter's answer, and the product change is a ticket only when it stands on its own as a change worth making.

Tasks are not dropped and they are not replied to. They are named in the run summary under what needs a human, and that is their only output: no ticket, no queued Slack reply. Do not perform one either — this skill writes tickets, and touching customer data unattended is out of the question.

### One thread can produce several tickets

People routinely pile three unrelated issues into one thread. Collapsing those into a single ticket makes the work impossible to prioritize, estimate, or split, so **split the thread instead**.

**The split test: two asks belong on separate tickets if they could be scheduled, prioritized, or shipped independently.** Apply it literally.

- A clarification, a repro, a screenshot, or extra detail on an ask you already captured is **not** a new ticket. It is more context on that one.
- Two bugs in the same screen are two tickets if either could ship without the other.
- A thread can also produce **zero** tickets, or one ticket plus a decision to skip the rest.

Each ticket records the specific message it came from and **that message's** permalink, not the thread parent's.

## 3. Reconcile against Linear

Two passes over what Linear already holds, both feeding the same candidate pool.

### Dedupe the new candidates

Search open Linear issues for each candidate on the Dish Books team. Match on the substance of the ask, not the wording, and check attached links for the Slack permalink.

A duplicate gets a **comment on the existing ticket** recording the new report and its source, so the second reporter is visible. It never gets a new ticket.

### Pick up anything already in Triage that was never researched

**Tickets reach Triage by routes this skill did not create.** Someone files one in the Linear UI, a ticket comes back from Product Review, or another skill leaves one there. Without this pass those sit unresearched forever, because the Slack sweep only ever looks at its own window.

**This is the only intake path for a request that did not come through Slack.** There is no separate skill for turning a conversation into a ticket: the lead files a placeholder — a title, or a title and a line or two of prompt — and this run researches it into a finished ticket. Treat a placeholder as a first-class candidate, not as a ticket to leave alone because it is thin.

List every issue in **Triage** on the Dish Books team and add to this run's candidate pool any that is **not yet researched** — meaning it has **no estimate**, or a priority of **0 / None**. This skill always sets both, so their absence is a reliable signal that no research pass has touched the ticket.

**Two exclusions, both important:**

- **Skip anything with a comment from the lead.** That ticket is mid-conversation and writing research over it would bury the exchange. This skill's own question and assumption comments do not count — only a human's reply does.
- **Skip anything already carrying research.** A ticket with an estimate and a priority has been through this, and re-researching it would overwrite decisions a human may already have made.

These candidates skip step 2 — they are already tickets — and go straight into the research in step 5. In step 6 they are **updated in place, never recreated**, and rewritten like any other ticket, with whatever the lead wrote kept as the source. The title may be sharpened to state the outcome.

## 4. Ground yourself in the domain

Read [docs/standards.md](../../../docs/standards.md) and [docs/tests.md](../../../docs/tests.md) — enough to understand the domain, the vocabulary, and the constraints a ticket has to live within. Read [docs/ticket-style.md](../../../docs/ticket-style.md), and [docs/context-format.md](../../../docs/context-format.md) if any candidate looks likely to move a domain term.

Read `CONTEXT-MAP.md`, infer which context each candidate relates to, then read that `CONTEXT.md`.

## 5. Resolve every question you can

**This step parallelizes cleanly across candidates.** Fan it out, one research agent per candidate.

For each ambiguity or gap, close it in this order and stop at the first that works:

1. **The docs settle it.** `standards.md`, `tests.md`, or the relevant `CONTEXT.md` dictates the answer. Resolve it and cite the source.
2. **The code settles it.** The existing behavior of the system answers it. Find it, follow it, reference the file and line.
3. **A reasonable default settles it.** No doc or precedent, but an obvious low-risk reading exists. **Take it, write the ticket as though it holds, and post it as an assumption comment** (step 6.1) so the lead can veto it.
4. **Nothing settles it.** The call needs judgment, a real trade-off, or product intent that is not written down. **Post it as an open-question comment** (step 6.1) with your recommended answer, and do not invent an answer.

**Verify what the report claims.** A candidate whose claim does not survive is not written as a ticket; it goes in the run summary instead, named with what you found and what you ruled out, for the lead to answer the reporter.

Two limits on that:

- **Drop only on evidence**, a file and line or a query result. Not being able to reproduce something is not proof it does not happen; that is an open question on a ticket that still gets written.
- **Where only part of the report falls** — the cause is wrong but the symptom is real — the ticket covers the part that survives, written from what you found rather than from what was reported, and the run summary names the correction.

## 6. Write each ticket

Every surviving candidate is written with `save_issue`, **state `Triage`**, on the Dish Books team.

- **A candidate from Slack is created.**
- **A candidate picked up from Triage in step 3 is updated in place.** Never create a second ticket for work that already has one. Its description is rewritten into the four sections, and whatever it already said is preserved as its quoted source.

**Title and body follow [docs/ticket-style.md](../../../docs/ticket-style.md).** Read it before writing anything. It is the whole specification and this step does not restate it.

### 6.1 The comments

One comment per item, with `save_comment`. Never one comment holding a list — the lead answers them individually.

- **`**Open question:**`** — the question, then your recommended answer and why. Written so it can be answered cold, without re-reading the ticket.
- **`**Assumption, not confirmed:**`** — the default taken and one line of rationale.
- **`**Proposed split:**`** — the sub-issue boundaries and how estimate and priority divide across them. **Do not create the sub-issues.**
- **`**Backlog candidate:**`** — one line of reasoning.

**Priority.** Every ticket gets one. Nothing is created at `0` / None.

| Priority | Means |
|---|---|
| 1 Urgent | Actively breaking work or losing money right now; jumps the queue |
| 2 High | Real customer pain or a blocker for planned work; wants the next cycle |
| 3 Medium | Worth doing, no particular deadline pressure |
| 4 Low | Nice to have; fine if it waits several cycles |

**Estimate.** A Fibonacci estimate, aiming for **1, 2, or 3**. A **5 is a rare exception** for work that genuinely cannot be sliced. **Never 8 or higher.**

| Points | Rough feel | Shape of the work |
|---|---|---|
| 1 | a few hours | trivial, fully understood, one obvious place to change |
| 2 | ~half a day | understood, a little surface area, no real unknowns |
| 3 | ~a day | the biggest healthy ticket: clear approach, some moving parts |
| 5 | ~2–3 days | the exception: genuinely cannot be sliced |

**If the honest estimate is bigger than a 3** set the estimate to the total as a provisional figure and post the split as a comment per 6.1.

**If the work looks speculative or low-value**, say so in a comment opening `**Backlog candidate:**` with one line of reasoning. Proposing this is part of the job, not a failure: a queue that only ever moves forward accumulates work that crowds out real work.

**Labels:** `Customer Support` for `#customer-support`, `Internal Request` for `#product`, `Bug` for anything reported as broken behavior, plus `Improvement` or `Feature` only when obvious. **Never apply `Accountant` or `Tested`** — those are assigned by people. Note `save_issue`'s `labels` parameter replaces the whole set.

**Links:** the source URL, as `links: [{url, title: "Slack thread"}]`.

## 7. Queue the Slack replies

Draft **one reply per thread, not per ticket.** Where a thread produced several tickets the single reply lists them all, one line each: identifier, URL, and which ask it covers. That is how the reporter sees that all three of their issues were captured and none was dropped.

Say the tickets have been logged. **Do not promise when they will be planned or worked** — no dates, no priority language.

**A thread that produced no ticket gets no entry.** A thread whose ask was a task is not replied to here; it goes in the run summary and the lead handles it. Where a thread produced both, the reply lists the tickets and stays silent on the task.

Every Linear link is a Markdown link whose text is the URL and whose href is the same URL:

```
[https://linear.app/dishbooks/issue/DIS-1055](https://linear.app/dishbooks/issue/DIS-1055)
```

**Append these to the pending replies document**, ID `b14618ca-8f66-4f89-bf29-7fa84afce03e`, with `save_document`. Unlike the other handoff documents this one is **a queue, not a snapshot**: it accumulates until `triage-inbox` gets each reply into Slack as a thread draft, or the lead discards it, so a run appends and never overwrites. Entries already in it from an earlier run have not reached Slack yet and must survive this write. See [handoff-documents.md](../handoff-documents.md).

Each entry records the channel, the thread timestamp, the tickets it covers, and the exact reply text.

## 8. Advance the watermark

Only after the tickets exist, update `Triage watermark`, ID `357434d3-056d-4c1c-9cd4-34f98c01c41a`, with `save_document`, replacing the fenced JSON block and leaving the surrounding text intact.

**Advance to the ceiling of what this run actually examined** — the newest message timestamp per channel — never to "now". Anything that arrived mid-run was never looked at, and stopping at the ceiling is what makes it appear tomorrow instead of being stepped over.

**Do not advance it** if the window came from an explicit override in args.

## Close

State in one line: how many tickets were created, **how many already in Triage were picked up and researched**, how many question and assumption comments are waiting on the lead, how many duplicates were commented on, how many items were skipped and why, how many replies are now queued, and where the watermark landed.

Then name, one line each, the three kinds of thing this run found and did **not** turn into a ticket. Nobody else is going to find them, and they are the only output of the run with nothing behind it in Linear.

- **Every thread waiting on an answer** — the channel, the thread, and the unanswered question, so the lead can chase it.
- **Every task that needs a human** — what needs doing and for which customer.
- **Every report that did not hold** — what was claimed, what you found, and the evidence, so the lead can answer the reporter without repeating the research. Where the ticket covers only part of the report, say which part was dropped and why.

If the Triage sweep found nothing to pick up, say so — that is the healthy result, and its absence from the summary is indistinguishable from the pass not having run.

## Never plan past Triage

Every ticket this skill creates stays in `Triage`. It is researched and it carries a priority, an estimate and its open questions as comments, but it is **not** approved — the lead has not seen it yet.
