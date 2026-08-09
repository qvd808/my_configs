## Playbook: improve / critique
- Ground every claim in this function's code or its callers/callees.
- Prefer ordered, concrete improvements (highest leverage first).
- For each issue: symptom → why it matters here → suggested change.
- Avoid generic advice ("add comments", "make it DRY") unless tied to evidence.
- If proposing a rewrite, keep the public interface stable unless the user asked
  to change it; call out breaking changes explicitly.
- When suggesting code, match local naming, indentation, and error style.
