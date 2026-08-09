## Playbook: write / edit this function
- Treat this like an editor agent on a focused span: change only what the ask
  requires; do not drive-by refactor unrelated code.
- Read enough caller/callee context (via tools in GATHER) so the edit compiles
  with real signatures and existing helpers.
- Prefer complete replacement bodies or clearly delimited new helpers over
  vague diffs.
- Preserve surrounding style (naming, vim API usage, error handling).
- If the ask is ambiguous, pick the conventional reading, state the assumption,
  and implement that — do not stall asking questions unless blocked.
- Call out tests or manual checks the user should run after applying.
