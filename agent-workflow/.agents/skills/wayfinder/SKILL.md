---
name: wayfinder
description: Plan a huge chunk of work (more than one agent session can hold) as a shared map of decision tickets on your issue tracker, and resolve them one at a time until the way to the destination is clear.
disable-model-invocation: true
---

A loose idea has arrived, too big for one agent session, and wrapped in fog: the way from here to the **destination** isn't visible yet. Wayfinding is about finding that way, not charging at the destination. This skill charts the way as a **shared map** on the repo's issue tracker, then works its **decision tickets** (questions whose resolution is a decision, not slices of a build to execute) one at a time until the route is clear.

The destination varies per effort, and naming it is the first act of charting: it shapes every ticket. It might be a spec to hand off and iterate on, a decision to lock before planning starts, or a change made in place like a data-structure migration. The map is domain-agnostic: engineering work, course content, whatever fits the shape.

## Plan, don't do

Wayfinder is **planning** by default: each ticket resolves a decision, and the map is done when the way is clear, with nothing left to decide before someone goes and does the thing. The pull to just do the work is usually the signal you've reached the edge of the map and it's time to hand off. An effort can override this in its **Notes**, carrying execution into the map itself, but absent that, produce decisions, not deliverables.

## Refer by name

Every map and ticket is an issue, so it has a **name**: its title. In everything the human reads (narration, the map's Decisions-so-far), refer to it by that name, never by a bare id, number, or slug. A wall of `#42, #43, #44` is illegible; names read at a glance. The id and URL don't vanish; a name wraps its link, but they ride _inside_ the name, never stand in for it.

## The Map

The map is a single issue on this repo's issue tracker, labelled `wayfinder:map`, the canonical artifact. Its tickets are child issues of the map.

The map is an **index**, not a store. It lists the decisions made and points at the tickets that hold their detail; a decision lives in exactly one place, its ticket, so the map never restates it, only gists it and links.

**Where the map, its child tickets, blocking, and frontier queries physically live is tracker-specific.** If the repo's `CLAUDE.md` / `AGENTS.md` points at a tracker doc, consult its "Wayfinding operations" section. Otherwise, use the [Local tracker](#local-tracker) below. It is the default, and it never writes to the repo or to a remote tracker.

### The map body

The whole map at low resolution, loaded once per session. Open tickets are **not** listed: they are open child issues, found by query.

```markdown
## Destination

<what reaching the end of this map looks like: the spec, decision, or change this effort is finding its way to. One or two lines; every session orients to it before choosing a ticket.>

## Notes

<domain; skills every session should consult; standing preferences for this effort>

## Decisions so far

<!-- the index: one line per closed ticket, enough to judge relevance, then zoom the link for the detail the ticket holds -->

- [<closed ticket title>](link): <one-line gist of the answer>

## Not yet specified

<!-- see "Fog of war": in-scope fog you can't ticket yet; graduates as the frontier advances -->

## Out of scope

<!-- see "Out of scope": work ruled beyond the destination; closed, never graduates -->
```

### Tickets

Each ticket is a **child issue** of the map; the tracker's issue id is its identity. Its body is the question, sized to one 100K token agent session:

```markdown
## Question

<the decision or investigation this ticket resolves>
```

Each ticket carries a `wayfinder:<type>` label, one of `research`, `prototype`, `grilling`, `task` (see [Ticket Types](#ticket-types)).

A session **claims** a ticket by assigning it to the dev driving the map, **first**, before any work, so concurrent sessions skip it. That assignee _is_ the claim: an open, unassigned ticket is unclaimed.

Blocking uses the tracker's **native** dependency relationship: essential because it renders the frontier _visually_ in the tracker's own UI, so the human sees what's takeable without opening the map. Only a tracker that lacks native blocking falls back to a body convention. A ticket is **unblocked** when every ticket blocking it is closed; the **frontier** is the open, unblocked, unclaimed children, the edge of the known.

The answer isn't part of the body; it's recorded on resolution (see [Work through the map](#work-through-the-map)). Assets created while resolving a ticket are linked from the issue, not pasted in.

## Local tracker

The default tracker: plain Markdown files in one store shared by every project, outside every project repo, so nothing leaks into a repo by accident.

- **Store**: `/home/sesa803779/wayfinder/`, a local Git repo (never pushed by the agent). Its `README.md` describes the layout.
- **Project**: the basename of the current repo's root (`git rev-parse --show-toplevel`), e.g. `saturn-v2-scc`.
- **Map**: `<store>/<project>/<MAP-ID>/MAP.md`, whose first line is `# <map title>`, followed by the map body. `<MAP-ID>` is the work item's key when invoked with one (e.g. `SCC2-1128`), else a short kebab-case slug of the destination. Put the source link and `Label: wayfinder:map` under the title.
- **Child ticket**: `<store>/<project>/<MAP-ID>/tickets/NN-<slug>.md`, numbered in creation order. Its first line is `# <ticket title>`, followed by these header lines, then the ticket body:

  ```markdown
  - Label: wayfinder:<type>
  - Status: open | claimed | closed | out-of-scope
  - Blocked by: NN, NN   (or none)
  ```

- **Blocking**: the `Blocked by` line. Wire it in the second pass, after every ticket has a number. A ticket is unblocked when every listed ticket is `closed`.
- **Frontier query**: tickets with `Status: open` and no unclosed blocker. Lowest number first.
- **Claim**: set `Status: claimed`, the session's first write.
- **Resolve**: all writes in one pass, without asking. Append `## Resolution` with the answer to the ticket, set `Status: closed`, and append a context pointer (gist + relative link) to the map's Decisions-so-far. The map file carries the answers, so there is no separate map comment.
- **Research findings**: write them in the ticket under `## Findings` rather than on a `research/<name>` branch.
- **Commit**: after charting and after each resolution, `git -C <store> add -A && git -C <store> commit -m "<project>/<MAP-ID>: <what changed>"`. Never push.
- **Existing map**: if `<store>/<project>/<MAP-ID>/MAP.md` exists, the invocation means "Work through the map", not "Chart the map".

### External work items are read-only input

A work item key (Jira such as `SCC2-1128`, GitHub, Linear) passed to `/wayfinder` is the **loose idea**, not a tracker. Fetch it with whatever tool the host provides (for Jira, the Atlassian MCP `jira_get_issue` with comments and `update_history: false`). Then show the user its summary and acceptance criteria, and chart from there. **Never write to the external tracker**: no issues, comments, links, labels, assignments, or transitions. All mapping goes to the local store.

## Progress-only updates

When the user asks to preserve interim findings across sessions without
resolving a ticket:

- In the Local tracker, append a dated `## Progress update` to the ticket.
  Keep the original question intact and include the evidence, current status,
  and remaining checks.
- Leave the ticket's `Status` unchanged. Do not claim, close, reopen, or
  otherwise transition it; the user decides whether and when to close it.
- Do not add an open ticket to `Decisions so far`, which indexes resolved
  decisions. If the user requests a map-level progress pointer, put it in a
  separate section and label it as in progress.
- Treat the update as context, not a resolution. Do not perform the
  resolution's four writes.
- Continue to follow the applicable personal write-approval requirements.
  This skill alone does not grant an exception to them.

## Ticket Types

Every ticket is either **HITL** (human in the loop, worked _with_ a human who speaks for themselves) or **AFK**, driven by the agent alone. A HITL ticket only resolves through that live exchange; the agent never stands in for the human's side of it (a grilling agent that answers its own questions has broken this).

- **Research** (AFK): Reading documentation, third-party APIs, or local resources like knowledge bases to surface a fact a decision waits on. Use a background agent following the `research` skill when the host supports it; otherwise do the research directly. Use when knowledge outside the current working directory is required.
- **Prototype** (HITL): Raise the fidelity of the discussion by making a cheap, rough, concrete artifact to react to (an outline, a rough take, a stub, or UI/logic code) using the `prototype` skill or its procedure. Links the prototype as an asset. Use when "how should it look" or "how should it behave" is the key question.
- **Grilling** (HITL): Conversation. The default case. Use the `grilling` and `domain-modeling` skills or follow their procedures directly.
- **Task** (HITL or AFK): Manual work that must happen before a _decision_ can be made: nothing to decide, prototype, or research, but the discussion is blocked until it's done. Signing up for a service so its API can be judged, provisioning access, moving data so its shape can be seen. This is the one type that _does_ rather than decides, and it earns its place by unblocking a decision, not by delivering the destination. The agent drives it alone where it can (AFK); otherwise it hands the human a precise checklist (HITL). Resolved when the work is done; the answer records what was done and any resulting facts (credentials location, new URLs, row counts) later tickets depend on.

## Fog of war

The map is _deliberately_ incomplete: don't chart what you can't yet see. Beyond the live tickets lies the **fog of war**: the dim view of decisions and investigations you can tell are coming but can't yet pin down, because they hang on questions still open. Resolving a ticket clears the fog ahead of it, graduating whatever's now specifiable into fresh tickets, one at a time, until the way to the destination is clear and no tickets remain.

The map's **Not yet specified** section is where that dim view is written down: the suspected question, the area to revisit later. It's the undiscovered frontier _toward_ the destination: everything here is in scope, just not sharp enough to ticket. Write as loosely or as fully as the view allows; it doubles as a signpost for collaborators reading where the effort is headed.

**Fog or ticket?** The test is whether you can state the question precisely now, _not_ whether you can answer it now.

- **Ticket when** the question is already sharp, even if it's blocked and you can't act on it yet.
- **Not yet specified when** you can't yet phrase it that sharply. Don't pre-slice the fog into ticket-sized pieces: it's coarser than a ticket, and one patch may graduate into several tickets, or none, once the frontier reaches it.

**Not yet specified** excludes what's already decided (Decisions so far), what's already a live ticket, and what's out of scope (the next section).

## Out of scope

Fog only ever gathers _toward_ the destination. The destination fixes the scope, so work beyond it is **out of scope**: it isn't fog, and it doesn't belong in **Not yet specified**. It gets its own **Out of scope** section on the map: work you've consciously ruled out of _this_ effort. Scope, not sharpness, lands it here.

Out-of-scope work never graduates (the frontier stops at the destination), so it returns only if the destination is redrawn, and then as a fresh effort, not a resumption.

Ruling something out of scope is a scoping act, not a step on the route. When a ticket that already exists turns out to sit past the destination (mis-scoped in while charting, or exposed by a resolution), **close it** (a closed ticket is unambiguously off the frontier) and leave one line in the **Out of scope** section: the gist plus why it's out of scope, linking the closed ticket. It stays out of **Decisions so far**, which records the route actually walked; a scope boundary isn't a step on it.

## Invocation

Two modes. Either way, **never resolve more than one ticket per session**, with the exception of research tickets.

### Chart the map

User invokes with a loose idea.

1. **Name the destination.** Use the `grilling` and `domain-modeling` skills, or follow their procedures directly, to pin down what this map is finding its way to: the spec, decision, or change. The destination fixes the scope, so it's settled first. Write nothing to the tracker until steps 1 and 2 are done and the user confirms the shared understanding.
2. **Map the frontier.** Grill again, **breadth-first** this time: fan out across the whole space rather than deep on any one thread, surfacing the open decisions and the first steps takeable now. **If this surfaces no fog** (the way to the destination is already clear, the whole journey small enough for one session), you don't need a map. Stop and ask the user how they'd like to proceed.
3. **Create the map** (label `wayfinder:map`): Destination and Notes filled in, Decisions-so-far empty, the fog sketched into **Not yet specified**.
4. **Create the tickets you can specify now** as child issues of the map, then wire blocking edges in a **second pass** (issues need ids before they can reference each other). Wiring sorts them into the frontier and the blocked; everything you can't yet specify stays in the fog: the **Not yet specified** section.
5. **Fire the research subagents.** For each `research` ticket you just created, use the host's background-agent capability to follow the `research` skill and resolve it in parallel, capturing its findings on a throwaway `research/<name>` branch with a context pointer from the ticket. If background agents are unavailable, resolve the tickets sequentially in the current session.
6. Stop: charting is one session's work; it hand-resolves nothing.

### Work through the map

User invokes with a map (URL or number). A ticket is **optional**: without one, you pick the next decision, not the user.

1. Load the **map**: the low-res view, not every ticket body.
2. Choose the ticket. If the user named one, use it. Otherwise take the first frontier ticket in order. **Claim it**: assign it to yourself before any work.
3. Resolve it. **Zoom as needed**: fetch the full body of any related or closed ticket on demand; use the skills named in the `## Notes` block, or follow their procedures directly if separate skill invocation is unavailable. If in doubt, use `grilling` and `domain-modeling`.
4. Record the resolution — always all four writes in one pass, never asking first: post the answer as a **resolution comment on the ticket**, **close** the ticket, **post a resolution comment on the map issue too** (gist + pointer, so the map itself carries every answer), and **append a context pointer** to the map's Decisions-so-far.
5. Add newly-surfaced tickets (create-then-wire); graduate any fog the answer has made specifiable, clearing each graduated patch from **Not yet specified** so it lives only as its new ticket. If the answer reveals that a ticket (this one or another) sits beyond the destination, **rule it out of scope** rather than resolving it on the route. If the decision invalidates other parts of the map, update or delete those tickets.

The user may run unblocked tickets in parallel, so expect other sessions to be editing the tracker concurrently.
