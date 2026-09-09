---
name: triage-inbox
description: Clears the Linear Triage queue with the lead, taking tickets to Ready for Dev. Use when the user wants to "work triage", "check the triage inbox", "answer my comments", or send the queued Slack replies.
---

# Triage Inbox

The interactive half of the daily pass. A researched ticket in **Triage** carries a priority, an estimate, and a body of four sections; whatever still needs a human sits on it as comments, one item each. The lead reviews in Linear and responds one of three ways:

- **Moves the ticket to Ready for Dev** — nothing further is needed.
- **Replies to a comment, or leaves their own** — this skill folds each answer into the ticket and finishes it.
- **Leaves it alone** — not yet reviewed. Leave it.

**Only a human's comment counts as review.** A ticket carrying only the unanswered questions and assumptions it was written with is still waiting.

This skill is what turns the second case into a Ready-for-Dev ticket. It is not an intake pass; nothing here reads Slack for new requests.

## Operating constraint (read first)

**This skill writes Linear tickets, Linear comments, sub-issues on an approved split, and Slack drafts from the pending reply queue.** It never touches code or git, never opens a PR, and never moves a ticket past `Ready for Dev`. It never puts text into Slack — as a draft or a message — without showing that exact text and getting an explicit yes in this session, and it prefers leaving a draft for the lead to send over posting itself.

## 1. Read the queue

List every issue in **Triage** on the Dish Books team, and pull each with `get_issue` and `list_comments`.

Sort each into one of three buckets and tell the lead the counts before doing anything:

- **Has a comment from the lead** — the work of this session.
- **No lead comment, nothing outstanding** — researched, nothing left to answer. Offer to promote these as a batch; they are waiting only on someone saying yes.
- **No lead comment, questions or assumptions outstanding** — still awaiting review. Leave them. Say how many and how long they have been sitting, because a ticket nobody answers is a ticket nobody ships.

**A ticket with no research at all is waiting for tomorrow's 5am run, not for you.** Every ticket in Triage should carry a priority, an estimate and a written outcome. One that carries none — filed by hand in Linear, or returned from Product Review — is picked up and researched by the morning routine. Leave it, and say so in the counts.

Only invoke `prep-triage-inbox` scoped to that ticket if it is needed **today**. Do not research it from scratch here: this skill finishes tickets, it does not originate them, and doing it by hand is exactly the all-day session this pipeline was rebuilt to avoid.

## 2. Work each commented ticket

For each ticket, lead with **the ticket's title and a plain-language summary of what it is**, then what the lead said, then what you propose to do about it. The lead is working through a queue and does not hold each ticket in their head.

**Work in batches, not one ticket at a time.** A queue of fifteen tickets handled singly is fifteen round-trips for the lead, and most of them are a formality. Sort the queue by how much each comment actually disturbs its ticket, and present accordingly:

- **Clean fold-ins** — the comment answers an open question the way the ticket already assumed, or gives a direct instruction with no downstream consequence. Batch five to eight of these into one message and take one approval for the batch.
- **Vetoes and conflicts** — the comment contradicts an acceptance criterion, forces a change the ticket rules out, or rests on a premise the code disagrees with. Raise these on their own, with the consequence spelled out, because the answer changes what gets built. Never bury one inside a batch.

Where a batch is mostly clean but one ticket carries a conflict, save the clean ones and hold that one; do not stall the batch on it.

Read the comments as instructions, and act on what they actually say:

- **An open question is answered** — fold the answer into the body, in whichever of the four sections it belongs to. The answer changes the desired outcome or an acceptance criterion; it never becomes a section of its own.
- **An assumption is vetoed** — the correction replaces it, and **everything downstream of it is re-derived**. A corrected premise frequently invalidates more than the line it touches: a changed cause can collapse the reason the ticket existed. Re-check the outcome, the acceptance criteria, the estimate and the priority against the correction rather than editing one sentence.
- **A split is approved** — create the sub-issues from the split comment, each with its own priority, estimate and focused slice of the outcome and acceptance criteria. **Set `parentId` so Linear owns the hierarchy, and title each child by its own outcome alone** — never repeat the parent's identifier in a child's title, which puts two ticket numbers in the generated branch name and can link a PR to the wrong issue. The parent moves to the same exit as its children, keeping the breakdown as the umbrella over them.
- **The ticket is rejected** — `Backlog`, `Canceled`, or `Duplicate` as instructed, with a comment recording why. A `Duplicate` needs `duplicateOf` set; Linear refuses the state without the relation.
- **A new question is raised** — answer it if the docs or the code settle it, following the same ladder `prep-triage-inbox` uses. If it needs the lead, ask it as a comment and leave the ticket in Triage.

**Verify before you agree.** If a comment asserts something about the code or the data, check it. Today's most useful triage outcomes have come from finding that a ticket described behavior that was already fixed, was never built, or worked differently than reported.

### When a question genuinely needs an SME

Some questions need accounting expertise, real restaurant workflow knowledge, or what a customer actually meant — things the lead cannot answer alone. Those do not sit in Triage waiting.

Move the ticket to **Product Review**, add the `Monday` label, and post each question as its own comment opening `**For Monday:**`. Write each so an SME can answer it **cold**: the context they need, the options, and your recommended answer. They were not in this session and will not read the rest of the ticket. Mark the estimate provisional.

Questions never become a section of the ticket body. The body is only ever the four sections.

## 3. Show the ticket before every save

**Never write a ticket to Linear before the lead has read it.** Show the complete thing — title, the four sections, priority, estimate and exit — and wait for an explicit go.

The finished body follows [docs/ticket-style.md](../../../docs/ticket-style.md), and a `## Context updates` section follows [docs/context-format.md](../../../docs/context-format.md) exactly. Folding an answer in never adds a heading the style allows no room for.

There is no blanket approval and you never ask for one: a lead who approves a *format* has not approved the *content* of tickets they have not seen. If the lead corrects something, fold it in and show the ticket again before saving.

**Batching batches the approval, never the showing.** One "yes" may cover several tickets, but only tickets whose content was in front of the lead when they said it. So every ticket in a batch still gets its own summary, its own full body, and its own named exit — what collapses is the number of times the lead has to answer, not what they see.

**Always show the whole ticket as it will be saved. Never a diff, never a list of changes.** A ticket the lead read earlier in the session gets pasted again in full when it changes: "the acceptance criterion moves" is not something anyone can check, and a body assembled from a summary of edits is a body nobody has actually read. The four sections are short enough that this costs almost nothing, which is the point of keeping them short.

## 4. Choose the exit

Every ticket worked in this session leaves by exactly one route. Name it before writing.

- **Ready for Dev** — nothing outstanding. Outcome and acceptance criteria clear, priority and estimate set. This is the default and the goal.
- **Product Review + `Monday`** — a question genuinely needs an SME.
- **Backlog** — worth keeping, not worth doing now. **Propose this actively, but never apply it without the lead saying so in this session.** A recommendation on the ticket is not agreement, and neither is silence on a batch: `Backlog` is the one exit the lead has to name, because a ticket parked there is a ticket nobody sees again. Absent an explicit yes, leave it in `Triage` and say you are still waiting on the call.
- **Split** — sub-issues created per §2, each taking one of the routes above, and the parent taking the same route as its children.
- **Canceled / Duplicate** — as instructed.

**Never touch other labels** `save_issue`'s `labels` parameter replaces the whole set, so omit it entirely to leave labels alone, and when you do pass it, pass every label the ticket had before you worked it.

## 5. Send the queued Slack replies

Read the pending replies document, ID `b14618ca-8f66-4f89-bf29-7fa84afce03e`. It is a **handoff queue**: every entry in it is a reply the morning run wrote that has not reached Slack yet, possibly from several days of runs. An entry leaves the queue when its draft lands in Slack — from there the lead sends it themselves, in Slack, and the document has no further part in it.

Show the exact text of each, with the thread it belongs to. **Get explicit confirmation before doing anything with them, every run** — approving ticket work in §3 is not approval to touch a customer-facing channel.

### Re-read every draft against what this session decided

**A draft written at 5am can be a promise the lead spent the session rejecting.** The morning run drafted its reply from the ticket as it stood then; §2 has since vetoed assumptions, canceled tickets and narrowed scope. Before showing any draft, check it against the ticket's current state and rewrite it where they disagree. Expect a quarter of them to need it. The three shapes that recur:

- a ticket **canceled** in this session, whose draft still promises the customer the thing that is not being built,
- a ticket whose **approach was rejected**, whose draft still describes the rejected approach,
- a ticket **narrowed** so the reported case is now out of scope, whose draft still promises that exact case.

The last is the easiest to miss and the worst to send, because the ticket still exists and the link still resolves — it just no longer covers what the reporter asked for. Where that happens, the reply has to say so plainly rather than let the link imply otherwise.

Say which drafts you rewrote and why, and show the corrected text rather than the original.

### Draft in Slack by default

**Prefer `slack_send_message_draft` over `slack_send_message`.** Pass `channel_id` and the entry's `thread_ts`. The reply lands in the lead's Slack drafts, on the right thread, where they read it in context with the customer's own words above it and send it themselves. Use `slack_send_message` only when the lead explicitly asks you to post directly.

The tool's "only one attached draft per channel" limit applies to channel-level drafts. **Thread drafts do not collide**, so a dozen replies across two channels all draft fine as long as each carries its `thread_ts`.

### Clear an entry once its draft is in Slack

**Remove an entry as soon as its draft lands on the thread, or once the lead says to discard it.** The lead sends from their Slack drafts and tracks what is left there; an entry kept back "until it is really sent" is a second, staler copy of a list they are already working from, and next morning's run shows them text they have moved past.

So: draft the reply, then delete its entry in the same run. Keep an entry only when its draft never reached Slack — the lead withheld it, or the call failed. Say in the close which entries you cleared and which you held, and why.

Where a draft **could not** be sent and stays queued, **write any text you rewrote into the document**, replacing the stale version — otherwise the correction is lost and tomorrow's run shows the wrong text again.

Rewrite the document with the remaining entries; anything still queued must survive.

## 6. Close

Summarize grouped by exit: which tickets went to Ready for Dev with their priorities and estimates, which are waiting on Monday and how many questions each holds, which went to Backlog and why, what was split into what, and what was closed.

Give the **total points now sitting in Ready for Dev** — that is the pool [plan-next-cycle](../plan-next-cycle/SKILL.md) draws from on Thursday.

Then say what is still in Triage and why: how many are awaiting the lead's review, and how many are blocked on a question nobody has answered.

Name anything still queued and why it did not make it. A draft in Slack is a handoff, not a delivery — the lead still has to send each one, so do not report drafts as replies sent.

## Never implement here

**This skill finishes tickets.** Never write or change implementation code, never write tests, never edit `CONTEXT.md`, never create branches, never open a PR.
