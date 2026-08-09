## Playbook: split / extract helpers
- Identify cohesive chunks (validation, I/O, pure transform, orchestration).
- Propose named helpers with clear inputs/outputs and where they should live
  (same file vs module).
- Show how the parent function shrinks and how callers stay correct.
- Prefer sketch patches / before-after outlines over vague bullets.
- Do not extract code that is only used once unless it clarifies a hot path.
