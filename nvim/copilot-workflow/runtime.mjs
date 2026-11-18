import fs from "node:fs";
import { createHash } from "node:crypto";
import { pathToFileURL } from "node:url";
import { agentAction, busy, current, event, read, transact, userAction } from "./store.mjs";

export const instructions = `This chat drives one work unit through phases the human controls:
planning (talk, then propose a plan) -> the human approves it -> running (you work alone) -> review.
Use the ordinary bash tool for the local controller (no custom MCP server is needed).
Read state first and after compaction with exactly:
node "$NVIM_WORKFLOW_RUNTIME" get
Update it using this exact here-document shape (valid JSON between the WORKFLOW lines):
node "$NVIM_WORKFLOW_RUNTIME" update <<'WORKFLOW'
{"op":"problem","unit_id":"u1","attempt":1,"title":"Short outcome title","problem":"What we agreed to solve and why"}
WORKFLOW
Controller commands must be standalone bash calls. Do not combine them with checks or
other controller updates, and do not submit dependent updates in parallel.
Always use unit_id (the current unit's id, not the workflow id) and attempt from get.

PLANNING (status planning). This is plain conversation; the user's normal write gate still applies.
Do not start the work. First make sure you understand the problem: ask the user in chat, one focused
round of questions at a time, and look facts up yourself (read-only). When you and the user agree what
is being solved, record it with the problem update above. Then propose the plan:
{"op":"plan","unit_id":"u1","attempt":1,"todos":["Investigate",{"title":"Implement","depends_on":["t1"]}],"required_checks":["exact test command"],"commands":["git commit -m ..."]}
plan assigns t1,t2,... and dependencies gate progress. List in "commands" every privileged or hard-to-undo
command you will run (sudo, git commit/push/reset/clean/checkout/restore/stash, rm -r); only exactly
those are pre-approved. Anything not listed will ask the user. After plan the unit waits for the user, who
approves (a) or declines (d); on decline you return to planning: ask them what is missing, then replan.
If the user is unsure, keep talking. Do not propose a plan to get things moving.

RUNNING (status running, only after the human approved the plan). Work freely inside the plan; the write
gate no longer prompts for plan-scoped work. Other updates are:
{"op":"add_todo","unit_id":"u1","attempt":1,"title":"Newly discovered work","depends_on":[],"required_checks":[]}
{"op":"todo","unit_id":"u1","attempt":1,"id":"t1","status":"running"}
{"op":"todo","unit_id":"u1","attempt":1,"id":"t1","status":"done","evidence":"What was actually observed"}
{"op":"decision","unit_id":"u1","attempt":1,"question":"One consequential question"}
{"op":"ready","unit_id":"u1","attempt":1,"summary":"Reviewable result, validation and limitations","artifacts":["path"]}
If the plan turns out wrong or incomplete in a way that changes its scope, stop with a decision update.
Before changing code, include exact focused validation commands in required_checks.
Run those commands with the ordinary bash tool; the hook records actual exit codes.
Todo evidence and review summaries must distinguish observed facts from claims.
You may delegate bounded jobs; collect every background result before requesting review. Prefer one
accountable lead, not a mandatory agent swarm. Use long_context for subagents when supported; do not
choose a more expensive model unless the user requested it.
Finish with a ready update: a concise outcome, validation/limitations and artifact paths. It closes the
unit to further tools until human review in <leader>ac.
Use knowledge-note explanations when the user needs grounding, not for every change.
Never approve/accept/decline your own work or manipulate the controller's state files.
Do not treat ordinary chat follow-ups as approval or start another outcome implicitly.
Existing write gates and skill invocation rules still apply.`;

const toolName = (input) => (input.toolName ?? input.tool_name ?? "").split(/[./:]/).at(-1);
const argsOf = (input) => {
  const args = input.toolArgs ?? input.tool_input ?? {};
  return typeof args === "string" ? JSON.parse(args) : args;
};
const resultOf = (input) => input.toolResult?.textResultForLlm ?? input.tool_result?.text_result_for_llm ?? "";
const keyOf = (input) => {
  const id = input.toolCallId ?? input.tool_call_id;
  if (id) return `call:${id}`;
  return createHash("sha256")
    .update(JSON.stringify([toolName(input), input.agentId ?? "", argsOf(input)])).digest("hex");
};

// preToolUse delivers a batch {toolCalls:[{id,name,args}]}; post hooks deliver one call at a time
const callsOf = (input) => Array.isArray(input.toolCalls)
  ? input.toolCalls.map(({ id, name, args }) => ({
    ...input, toolCalls: undefined, toolCallId: id, toolName: name, toolArgs: args,
  }))
  : [input];

export function controllerCommand(input) {
  if (toolName(input) !== "bash") return null;
  const command = argsOf(input).command ?? "";
  if (command.trim() === 'node "$NVIM_WORKFLOW_RUNTIME" get') return "get";
  const update = command.match(/^node "\$NVIM_WORKFLOW_RUNTIME" update <<'WORKFLOW'\n([\s\S]+)\nWORKFLOW\s*$/);
  if (update) {
    JSON.parse(update[1]);
    return "update";
  }
  return null;
}

function bind(state, input) {
  const session = input.sessionId ?? input.session_id;
  if (!session) throw new Error("Hook omitted the Copilot session ID");
  if (state.session_id && state.session_id !== session) {
    throw new Error("Workflow belongs to another Copilot session; resume it from <leader>ac");
  }
  state.session_id = session;
  state.session_ids ??= [];
  if (!state.session_ids.includes(session)) state.session_ids.push(session);
}

function finishTool(unit, input) {
  const key = keyOf(input);
  if (unit.inflight[key] > 1) unit.inflight[key]--;
  else delete unit.inflight[key];
}

function observeResult(state, input) {
  const unit = current(state);
  const args = argsOf(input);
  const tool = toolName(input);
  const result = resultOf(input);
  const exit = result.match(/<shellId:\s*([\w-]+) completed with exit code (-?\d+)>\s*$/);
  if (tool === "bash" || tool === "read_bash") {
    unit.shells ??= {};
    const shell = exit?.[1] ?? [...result.matchAll(/<shellId:\s*([\w-]+)[^>]*>/g)].at(-1)?.[1] ?? args.shellId;
    if (tool === "bash" && shell) unit.shells[shell] = args.command;
    const command = tool === "bash" ? args.command : unit.shells[shell];
    if (command && exit) {
      unit.checks.push({ command, exit_code: Number(exit[2]), attempt: unit.attempt });
    }
  }
  if (tool === "task" && args.mode === "background") {
    const id = result.match(/agent[_ -]?id["':\s=]+([\w-]+)/i)?.[1];
    if (!id) throw new Error("Cannot identify the background agent from task result; workflow remains blocked");
    const existing = unit.jobs.find((job) => job.id === id);
    if (!existing) unit.jobs.push({ id, name: args.name ?? args.description ?? id, status: "running" });
    const job = unit.jobs.find((item) => item.id === id);
    job.collected = false;
    event(state, "agent_started", id);
  }
  if (tool === "write_agent") {
    const ids = args.agent_ids ?? (args.agent_id ? [args.agent_id] : unit.jobs.map((job) => job.id));
    for (const id of ids) {
      let job = unit.jobs.find((item) => item.id === id);
      if (!job) {
        job = { id, name: id };
        unit.jobs.push(job);
      }
      job.status = "running";
      job.collected = false;
      event(state, "agent_resumed", id);
    }
  }
  if (tool === "read_agent") {
    const job = unit.jobs.find((item) => item.id === args.agent_id);
    const status = result.match(/(?:status["':\s=]+|agent (?:is )?)(completed|idle|failed|cancelled)\b/i)?.[1];
    if (job && status) {
      job.status = status === "idle" ? "completed" : status;
      job.collected = true;
      event(state, "agent_reported", job.id);
    }
  }
}

export function hook(file, kind, input) {
  if (!file || !read(file)) {
    if (process.env.NVIM_WORKFLOW_REQUIRED === "1") throw new Error("Required workflow state is missing; reopen it from <leader>ac");
    return {};
  }
  let output = {};
  transact(file, (state) => {
    bind(state, input);
    const unit = current(state);
    const tool = toolName(input);
    if (kind === "start") {
      state.runtime_pid = process.ppid;
      event(state, "connected");
      output = { additionalContext: `${instructions}\nCurrent unit:\n${JSON.stringify(unit)}` };
    } else if (kind === "pre") {
      const open = unit.status === "running" || unit.status === "planning";
      const counted = [];
      for (const call of callsOf(input)) {
        const control = controllerCommand(call);
        const get = control === "get";
        const update = control === "update";
        const drain = ["read_agent", "list_agents", "stop_bash", "read_bash"].includes(toolName(call));
        if ((!get && !drain && !open) || (update && call.agentId)) {
          output = {
            permissionDecision: "deny",
            permissionDecisionReason: `Unit is ${unit.status}. Only the user in <leader>ac can resume or approve it. Workers cannot change the lead's unit.`,
          };
          break;
        }
        if (!get && !update) counted.push(keyOf(call));
      }
      if (!output.permissionDecision) {
        for (const key of counted) unit.inflight[key] = (unit.inflight[key] ?? 0) + 1;
      }
    } else if (kind === "post" || kind === "failure") {
      finishTool(unit, input);
      if (kind === "failure") {
        event(state, "tool_failed", input.error ?? tool);
        const args = argsOf(input);
        const command = tool === "bash" ? args.command : tool === "read_bash" ? unit.shells?.[args.shellId] : null;
        if (command && !controllerCommand(input)) {
          unit.checks.push({ command, exit_code: null, attempt: unit.attempt, error: input.error ?? "Tool failed" });
        }
      }
      else if (!controllerCommand(input)) observeResult(state, input);
    } else if (kind === "child-stop") {
      const id = input.agentId ?? input.agent_id;
      if (!id) throw new Error("Subagent stop hook omitted agent ID");
      const job = unit.jobs.find((item) => item.id === id);
      if (job) job.status = "completed";
      else if (state.units.slice(0, state.active).some((item) => item.jobs.some((previous) => previous.id === id))) {
        event(state, "stale_agent_completion", id);
        return state;
      } else unit.jobs.push({ id, name: input.agentName ?? id, status: "completed", collected: true });
      event(state, "agent_completed", id);
    } else if (kind === "stop" && unit.status === "running") {
      if (!input.stop_hook_active) {
        output = {
          decision: "block",
          reason: 'Finish the active work unit: run node "$NVIM_WORKFLOW_RUNTIME" get, then update todos and submit ready with evidence, or ask a blocking decision. Use the exact update here-document from the session instructions. Do not silently finish without updating its state.',
        };
      } else {
        unit.status = "paused";
        event(state, "paused", "Agent ended its turn without submitting a review or decision");
      }
    }
    return state;
  });
  return output;
}

async function main() {
  const [mode, kind] = process.argv.slice(2);
  const file = process.env.NVIM_WORKFLOW_FILE;
  if (!file) throw new Error("NVIM_WORKFLOW_FILE is not set");
  const input = mode === "get" ? null : JSON.parse(fs.readFileSync(0, "utf8"));
  let output;
  if (mode === "get") {
    output = read(file);
    if (!output && process.env.NVIM_WORKFLOW_REQUIRED === "1") throw new Error("Required workflow state is missing");
    output ??= { active: false };
  }
  else if (mode === "ui") output = transact(file, (state) => userAction(state, input));
  else if (mode === "update") output = transact(file, (state) => agentAction(state, input));
  else if (mode === "hook") output = hook(file, kind, input);
  else throw new Error(`Unknown runtime mode: ${mode}`);
  process.stdout.write(`${JSON.stringify(output)}\n`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(fs.realpathSync(process.argv[1])).href) {
  main().catch((error) => {
    process.stderr.write(`nvim-workflow: ${error.message}\n`);
    process.exitCode = 1;
  });
}
