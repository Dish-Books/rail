---
name: plan-next-cycle
description: Build the upcoming Linear cycle on the Thursday before it starts. Checks the current cycle is actually ending, collects every Ready for Dev candidate with its priority estimate and labels, derives a point budget from recent velocity normalized for cycle length and confirms it with the lead, fills that budget in priority order, then assigns the approved set to the upcoming cycle in Linear so the priority meeting works off Linear itself. Use when the user wants to "plan the next cycle", "build the upcoming cycle", or prepare the cycle recommendation.
---

# Plan Next Cycle

Thursday morning of week 2, before the priority meeting. Ready-for-Dev candidates → velocity-derived budget → priority-ranked composition built directly in Linear. The recommendation lives in Linear rather than in a chat message, because **Linear is the view the meeting works off**.

Running it in the morning leaves hours to react before the 2pm meeting. What the meeting does is argue with a concrete proposal, not build one from scratch.

## Operating constraint (read first)

**This skill writes cycle assignments to Linear and nothing else.** It does not change ticket requirements, priorities, estimates, or states, and it never touches code or git. If a candidate turns out to be badly estimated or wrongly scoped, say so and leave it out — fixing it belongs to [triage-inbox](../triage-inbox/SKILL.md), not here.

**Never touch anything in the current cycle.** Planning happens with days of the current cycle left to run, so its tickets are still live work. Whatever is unfinished when the cycle closes rolls over automatically — it does not need to be moved, re-assigned, or planned for. Do not add to the current cycle, remove from it, or pull its issues into the upcoming one.

## 1. Identify the cycles

Identify the current cycle and the one after it, and confirm the target cycle with the user before going further.

Reference cycles by **ID or number only** — a title-based query fails silently and returns nothing, which looks exactly like an empty backlog.

## 2. Collect the candidates

List every issue in **Ready for Dev** for the team, with its priority, estimate, and labels.

**Ready for Dev is the only source.** Do not include Product Review tickets, however promising, and regardless of any provisional estimate they carry. A ticket with an unanswered SME question is not plannable work, and pulling it in is how a cycle fills up with things that stall on day three.

Flag and exclude two kinds of broken candidate:

- **No estimate** — it cannot be budgeted against.
- **Priority 0 / None** — every ticket is created with one, so this means a ticket slipped through.

## 3. Derive the point budget, then confirm it

Read the last two to three cycles and take the **final value of each one's `completedScopeHistory`** — points actually completed, not scoped.

**Normalize for cycle length before averaging.** Cycle lengths have changed: cycle 26 (`Week 31`) was a **one-week** cycle that completed 46 points, while cycle 27 (`Cycle 32`) is **two weeks**. Compare points *per week*, then multiply by the length of the cycle you are planning. Averaging raw per-cycle totals across a length change halves the budget and quietly under-fills the cycle.

Show the arithmetic, not just the answer:

```
cycle 26  46 pts / 1 week  = 46 pts/week
cycle 27  ?? pts / 2 weeks = ?? pts/week
trailing average           = ?? pts/week
target cycle is 2 weeks    → suggested budget ?? pts
```

Then **ask the user to confirm the budget, every run.** Never proceed on the derived number alone. Velocity is a starting point; holidays, a half-week of meetings, or someone being out are all things only they know about.

## 4. Fill the budget by priority

Fill the confirmed budget in priority order, highest first, regardless of label. Within a priority, prefer the work that fits the remaining points cleanly over splitting the tier arbitrarily.

**Do not pad to hit the budget.** If the priority-ranked candidates run out before the budget does, report the shortfall in points and leave it unallocated rather than reaching for low-value work.

## 5. Build it in Linear

Show the proposed composition first: an ordered list within budget, each line giving the ticket, priority, estimate, and label. Then the **cut line**, and below it what didn't fit and why.

Get explicit approval. Then assign the approved issues to the upcoming cycle with `save_issue`, referencing the cycle by ID or number.

- **Confirm the target cycle again** immediately before writing — every write goes to the upcoming cycle, never the current one.
- **Report anything already in the upcoming cycle that you are now removing.** Removing work someone has started is a real consequence and must never be silent.
- Assign only. Do not change any ticket's state, priority, estimate, or labels here.

## 6. Hand off to the meeting

Close with a short brief for the 2pm meeting:

- What's in, totalled.
- What's on the cut line and why.
- **A short "what I'd argue for" paragraph** — the one or two calls in this composition that are genuinely debatable, and where you'd hold the line. This is the part that makes the meeting a decision rather than a read-out.

Note that the composition is live in Linear, so the meeting can adjust it there directly.
