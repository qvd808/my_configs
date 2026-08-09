State: ANSWER — function-domain workflow.

Intents: {{intents}}

Write the final markdown answer from the brief + tool results already in
this conversation. Call emit_answer exactly once.

emit_answer requires:
- answer: full markdown for the user (follow the playbook for the intents)
- checklist: { behavior, interface, architecture, user_ask, gaps? }

Quality bar (Cursor-style edit discipline when intents include implement/critique/split):
- Only change what the user asked for; no unrelated drive-by refactors.
- Match existing style and real APIs from evidence.
- Prefer complete function bodies / helper sketches over hand-wavy steps.
- State assumptions when the ask was ambiguous.

If evidence is still insufficient, emit_answer anyway with honest checklist.gaps;
the harness may send you back to GATHER if the contract fails.
