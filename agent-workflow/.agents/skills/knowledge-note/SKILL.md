---
name: knowledge-note
description: Structure explanation notes so they teach in dependency order — the goal first, the baseline before the deviation, the mechanism before the project's decision. Use this whenever writing or revising a conceptual or explanatory document, whenever a draft turned out hard to follow, whenever a reader could not tell what a section was building toward or why it appeared where it did, and whenever a document mixes general concepts with project-specific choices or uses a term before defining it.
---

# Knowledge notes

An explanation note answers *can you tell me about this?* The reader arrives without the
theory and leaves able to review a decision without reconstructing it first. It is not a
decision record and not a tutorial.

Content is rarely the problem. Order is. A note fails when it is arranged by the argument the
writer was having rather than by the dependency graph the reader is climbing: a sequence of
true, well-sourced paragraphs the reader cannot assemble, because each one presumes something
the note has not yet given them.

## Reference

`NOTE-SHAPE.md` holds three things. Load the one the branch you are on needs; do not read it
whole.

- **The skeleton** — the section template. Load it before writing §1 of a new note.
- **The checklist** — Goal, Dependency order, Baseline, Decision sections, Shape,
  Preservation, and the project-specific Sources and citations group. Load it at the
  checklist step of either workflow — step 7 when writing, step 6 when revising — and load
  only the group you are checking if you are checking one.
- **Worked example: what went wrong in note 02** — a real note's ladder in finished form.
  Load it when building a ladder, as the output format.

`references/rationale.md` holds the sources behind the invariants. Load it only when deciding
whether a rule should change. Executing the skill never requires it.

## Rule 0 — Decide whether restructuring is warranted

Run this before anything else, and run it honestly. A skill about reordering will find
reordering work in any document; that is not the same as the document needing it.

Sort every finding into one of two lists.

**Blocking** — a reader cannot proceed. Fix these.

- A term is used before any definition the reader could have reached.
- A deviation is taught before its baseline.
- There is no §1 goal, or §1 opens on mechanism.
- A prerequisite line points forward.
- The route in §1 is missing, or describes an order the note no longer has.
- A section ends without naming what the next one picks up.
- A concept and a decision about it are nested rather than sibling.
- A decision section states costs before options.

**Cosmetic** — a reader gets through fine. Report these; do not apply them unasked.

- An order that is defensible but not the one you would have picked.
- Heading depth and section naming.
- An example arriving after its rule where the rule reads fine first.

Two things this rule protects against. A term introduced late in a section the reader has
already been prepared for is not a finding. And if every finding is cosmetic, say so and
stop — a note that reads correctly does not need a ladder rebuilt around it.

## Building the ladder

Build it before writing prose, every time. For a short note it is five terms and takes a
minute. It is not skippable because a note feels small; every note feels small from inside,
and forward references are what skipping produces.

1. **List the terms.** Every technical term the finished note will use — `lexer`, `token`,
   `trivia`, `left-associative`, `TCB`, all of them. Include terms borrowed from earlier
   notes.
2. **For each term, name where it is defined.** A section of this note, a specific section of
   an earlier note (`note 01 §4`), or "assumed — the reader has this already." A term with no
   defining location is a hole, and that hole is a section you have not written yet.
3. **Draw the edges.** Term A depends on term B if A cannot be explained without B.
4. **Order the sections so every edge points backwards.** A term's defining section comes
   before every section that uses it. No exceptions, including for a term everybody knows.

**Where the ladder lives.** Write it out as a table whenever the note will run past roughly
six sections, and always when revising an existing note; otherwise keep it in reasoning. Show
the written ladder to the author before writing prose. `NOTE-SHAPE.md` ends with a worked one
— *what went wrong in note 02* — in the finished form: rung, section, and what it needs.
Load that section, not the file.

The ordered list is the note's skeleton; write the prose into it. If while writing you need a
term the ladder places later, the ladder was wrong. Fix the ladder — do not write a forward
reference.

## Invariants

These have no exceptions, and each is checkable against the finished note.

### I1 — §1 is the goal, and its shape is fixed

Four questions, in this order, before any mechanism appears.

- **What exists at the end.** The concrete artifact in the project's own terms: a signature, a
  type, a checked property. Not "we will study parsing" but a function
  `parse(&str) -> Result<NamedTerm, ParseError>`, so tests can write `(\x. x) y`.
- **Why now.** What is blocked or expensive without it, and what changes if the note is
  skipped. Say plainly when the answer is that nothing mathematical is missed.
- **What this note does not cover.** The boundary.
- **The route.** Every `##` section that follows, in order, one clause each, and why the
  order is that one — which section exists only because the one before it left something
  unfinished. This is the ladder, stated for the reader in prose.

This is what the reader holds in their head for everything that follows. Without it, every
later section is a fact with nowhere to attach.

The route is written last, after the note is finished and the section order has stopped
moving, and it is rewritten whenever a section moves. A route describing an older order is
worse than no route: the reader trusts it and is then lost.

Write it for a reader who already knows the topic. They are not reading to learn what a lexer
is; they are reading to find out what *this* note does with one, and in what order, so they
can skip to the rung they came for or follow the argument through. Naming the sections is not
enough — the reason each one follows the last is the part that carries them.

### I2 — Baseline before deviation

Whenever the note describes a choice that departs from ordinary practice, the ordinary
practice gets its own section, taught as if unknown, before the words "instead" or "does not"
appear. Naming the standard approach is not teaching it.

That section owes the reader the pipeline or shape drawn out with each stage's input and
output named; the vocabulary that stage introduces, defined on first use; and why anyone does
it that way — the problem the standard approach solves.

A deviation section may not introduce baseline vocabulary. Defining a term inside the
paragraph that rejects it means the baseline section is missing.

### I3 — Concept and decision are siblings, never nested

A topic containing a choice splits into two consecutive sections at the same heading level:

- **How it works** — the mechanism, taught neutrally, with no project choice in it.
- **What this project picked, and why** — the choice and its trade-off.

If the decision needs five parts, those are five parts of the decision section, not `§3.1.4`
hanging off the concept.

### I4 — Decision sections run in one fixed order

1. **The problem the choice is about**, restated in one or two sentences in this note's terms.
2. **The options as they exist in the wild** — each on its own terms, neutrally, with its
   source, described so a competent person's reason for picking it is visible.
3. **The choice, stated plainly.**
4. **What it costs**, and the invariant or rule that pays that cost.
5. **What the choice does not buy** — the rationales that sound right and are wrong.
6. **What it actually buys.**

Costs and non-reasons before options is the most common ordering mistake in this genre: the
reader is asked to weigh a trade-off against alternatives they have not been shown.

### I5 — Every `##` section declares its prerequisite

Italic, immediately under the heading: *Needs: §2.1, and note 01 §4.* Or *Needs: nothing
before it.*

This is what makes the ladder visible to the reader and checkable by you. A prerequisite line
pointing forward means the note is out of order.

### I6 — Every `##` section hands off to the next one

A section ends by naming what it has left unfinished, in one or two sentences, and that is
what the next section opens on. Not a summary of what was just said — the reader has just
read it. The unresolved thing: the case the mechanism does not cover, the term now defined
but not yet used, the choice the section has just made unavoidable.

The pairing is the check. `*Needs: §3.*` at the top of §4 and §3's closing sentence are the
same edge of the ladder seen from both ends, and they have to agree. When you cannot write
the handoff — when §3 finishes and leaves nothing open that §4 picks up — the two sections
are not adjacent rungs, and either the order is wrong or a section is missing between them.

The last section hands off too: to what the note deliberately left undone, to the note that
takes the topic further, or to the ticket that will. If the answer is that nothing follows,
say that.

Together with I1's route, this is what lets a reader who already knows the topic follow the
argument rather than merely recognise the vocabulary: the route tells them where the note is
going, and each handoff tells them why it is taking the next step.

## Heuristics

Defaults, not invariants. Depart from them when the note is better for it, and note the
departure in your findings.

### H1 — Concrete instance before general rule

Within a section, the smallest real example comes before the statement it illustrates: the
term before the grammar, the trace before the invariant, the failing input before the rule
that rejects it.

Exception: when the example cannot be interpreted without the rule, state the rule first and
keep it short. Either way the general rule still gets stated precisely and in full — this is
only about which arrives first.

### H2 — Two heading levels

`##` and `###` only. Content wanting a fourth level is a section of its own, promoted. Manual
`§3.1.1`-style numbering below the second level is usually a symptom of a decision that should
have been split out under I3.

### H3 — Section count follows the ladder

However many rungs the dependency graph has. There is no target length and no target count.

## What this skill never does

**It never shortens.** Density is the point of these notes. Reordering is not a licence to cut
a quotation, a worked example, a trace, or a caveat. When a section moves, it moves whole. A
note getting *longer* because a missing baseline section had to be written is the expected
outcome.

Merging is allowed: if a passage now sits in two places, merge it into the earlier one and
leave a pointer. Deleting is not. If you believe material should be cut — a real duplicate, an
obsolete example, a tangent belonging elsewhere — that goes into the findings list as a
recommendation and stops there. The author decides.

This rule is deliberately absolute. The pull toward compression is strong enough that any
judgment call about what counts as redundant becomes the route by which a caveat gets deleted
for resembling an earlier sentence.

**It never summarises in place of explaining.** A summary paragraph is not a substitute for
the section it summarises.

**It never decides the project's direction.** Notes explain concepts.

## Writing a new note

1. Confirm the topic's boundary and the §1 goal with the author if the topic is new.
2. Build the ladder. Write it out and show it if the note will run past roughly six sections.
3. Write §1 from I1, into the skeleton in `NOTE-SHAPE.md` — everything but the route, which
   has nothing stable to describe yet.
4. Write the sections in ladder order, each opening with its prerequisite line (I5) and
   closing with its handoff (I6).
5. Write the route into §1, from the section order the finished note actually has.
6. Apply the project conventions below.
7. Run the checklist in `NOTE-SHAPE.md` — all groups.
8. Register the note.

## Revising an existing note

The note's *content* is assumed good. The job is the order.

1. **Build the ladder from the note as it stands.** For each term, find the line where the
   note first *uses* it and the line where it first *defines* it. Any term used before it is
   defined is a finding.
2. **Triage** every finding into blocking or cosmetic (Rule 0).
3. **Report both lists as moves** before rewriting anything — "§3.1 needs a baseline section
   before it", "§3.1.3 should run after §3.1.1". If the blocking list is empty, stop here.
4. **Apply the blocking moves.** Move whole sections. Write the missing baseline sections.
   Renumber.
5. **Rewrite the route in §1 and every handoff the moves invalidated.** A section that moved
   now closes on a different successor, and the route now describes a different order. This
   is the step most easily forgotten, and skipping it leaves the note pointing the reader
   somewhere it no longer goes.
6. Run the checklist in `NOTE-SHAPE.md` — Goal, Dependency order and Preservation at minimum.
7. **Report what changed and what you left alone**, including the cosmetic findings you did
   not act on.

## Project conventions

The following conventions apply only in the Personal Knowledge Base repository. In other
workspaces, follow that repository's own instructions, note locations, and citation rules.
This personal skill grants no write permission and does not override project policy.

- Notes live in `docs/knowledge/`. `NOTE-SHAPE.md` and `references/rationale.md` are part of
  this skill and live beside this file, not in `docs/knowledge/` — they are agent tooling,
  and `docs/knowledge/` holds only rendered notes.
- In the Personal Knowledge Base repository, `AGENTS.md` defines a narrow `docs/knowledge/`
  write exception associated with this skill. Follow its current approval and gate
  instructions exactly; this copied skill does not itself grant approval or bypass a gate.
  The exception does not cover deleting notes. In other repositories, do not assume this
  path or any write exception.
- The Personal Knowledge Base repository's `tools/write-gate/gate.mjs` and `npm run gate:note`
  are repository-specific. Use them only when that repository's `AGENTS.md` requires them.
  If a gate denies a write, stop and follow the current workspace's instructions.
- Each note opens with an italic preamble under the title: one or two sentences on what the
  note is for, including any honest warning about it. When a ticket drove the note, the
  preamble opens with the Lesson-ticket sentence — *Lesson note for
  [T\<n\>](\<issue url\>).* — and when none did, it simply starts with the purpose. Never
  invent a ticket to satisfy the shape.
- Each note ends with a self-check section, then `## Sources`.
- Every note gets a one-line row in `docs/knowledge/README.md`.
- In the Personal Knowledge Base repository, `AGENTS.md` § *Sources and citations* applies
  in full and this skill never relaxes it: every factual claim carries the URL actually fetched
  plus the work's title and identifier; a source that could not be fetched is reported as
  unfetched rather than cited from memory; anything worked out rather than read is marked as
  inferred, in those words; every path, filename, flag and command carries its `file:line`.
