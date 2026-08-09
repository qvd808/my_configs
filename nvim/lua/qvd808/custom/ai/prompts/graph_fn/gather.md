State: GATHER — function-domain workflow (may loop).

Intents: {{intents}}

Job: decide whether the domain brief is enough for those intents. If not,
call evidence tools, then either gather again or proceed_to_answer.

Evidence tools: read_range, hover, signature, list_symbols, grep, graph_neighbors.
Exit tool: proceed_to_answer({ reason, still_missing? }).

Do NOT write the final user-facing answer in this state.
Do NOT call emit_answer here.

Gather priorities by intent:
- explain/trace → callers/callees bodies, hover on focus
- critique/improve → focus body + callers (contracts) + similar patterns via grep
- split → full focus body + callees that might absorb chunks
- implement/write → focus body + callees'/helpers' signatures (hover/signature/read_range)
  before proposing code

Loop rule: each gather round should either pull new evidence or proceed.
If the brief already satisfies the intents, proceed_to_answer immediately.
