---
name: verify-resources
description: Verify that vault notes faithfully represent their Resources — fetch each source (transcripts for YouTube), judge fidelity per class, and report findings without editing any note. Use when the user asks to verify resources, check note-vs-source fidelity, or audit the references of one or more vault notes.
---

Verify that notes faithfully represent their Resources (#41). This is a
**manual agent session** — never part of the sync wrapper. You judge; you
never edit bodies.

## Scope

Default: every note with a `## Resources` section (the registry in
`knowledge/resources.md` is the roster). If the user names notes, verify only
those. Verdicts are keyed by Resource id (`res-…`).

## Procedure

1. **Enumerate** the Resources: read the `## References` registry of
   `knowledge/resources.md` (id ↔ URL) and, per declaring note, the
   `[[resources#^res-…|alias]]` lines in its `## Resources` section.
2. **Classify** by URL pattern only — no network probing:
   - `youtube.com/watch`, `youtu.be/`, `music.youtube.com` → **youtube**
   - path ending `.pdf` → **pdf**
   - everything else → **website**
3. **Group YouTube by video id** (the `v=` param or the `youtu.be` path
   segment): all Resources sharing a video id are verified **once** against
   that video, and the verdict is reported against every line sharing it.
   Verbatim URLs are never rewritten.
4. **Fetch and cache** under `.cache/verification/<res-id>/`
   (gitignored; never inside `knowledge/`). Skip the download when a cached
   copy exists. Use plain local tooling (`Invoke-WebRequest`, `curl`);
   use **yt-dlp** for YouTube transcripts (auto-generated English captions
   are acceptable). If yt-dlp is missing, mark those Resources
   `unverifiable (tool missing)` with an install hint — never silently skip.
5. **Judge fidelity per class**, quoting evidence from both sides:
   - **website**: resolves after redirects; topic matches the declaring
     note's usage; claims match page prose.
   - **pdf**: text extractable; claims match document content
     (author/title/section level).
   - **youtube**: transcript-level claim checking; title/description as
     baseline.
6. **Verdicts** — exactly one per Resource:
   `ok`, `dead` (unreachable after redirects), `drift` (source exists but
   topic doesn't match the note's usage), `unsupported-claim` (the note
   asserts something the source doesn't say), `misattribution` (wrong
   author/source credited), `unverifiable` (reason stated).
   Cosmetic title typos are not findings.
7. **Report**: write `.cache/verification/report-<YYYY-MM-DD>.md` with one
   row per Resource (id, class, verdict, evidence quotes from note and
   source), then summarize the table in chat.

## Hard rules

- The citation contract applies to every non-`ok` verdict: quote the note's
  claim AND the source passage that contradicts (or fails to support) it.
- Findings never block anything and never edit note bodies, the registry,
  or any generated file.
