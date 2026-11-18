import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { current, read, transact, userAction, agentAction } from "./store.mjs";
import { hook, controllerCommand } from "./runtime.mjs";

const runtime = fileURLToPath(new URL("./runtime.mjs", import.meta.url));

function fixture(t, { working = false } = {}) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "nvim-workflow-test-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const file = path.join(directory, "state.json");
  const user = (args) => transact(file, (state) => userAction(state, args));
  const raw = (args) => transact(file, (state) => agentAction(state, {
    unit_id: current(state).id, attempt: current(state).attempt, ...args,
  }));
  // Tests of the working phase propose a plan and have the human approve it; pass hold to stop at the proposal
  const agent = (args) => {
    if (args.op === "plan" && !current(read(file)).problem) raw({ op: "problem", problem: "Agreed problem" });
    const result = raw(args);
    if (args.op === "plan" && !args.hold && current(result).status === "awaiting_plan") {
      user({ op: "approve", revision: read(file).revision });
    }
    return read(file);
  };
  user({ op: "create", goal: "Research and demo together", cwd: directory });
  if (working) {
    transact(file, (state) => {
      current(state).status = "running";
      current(state).approved_attempt = current(state).attempt;
      return state;
    });
  }
  const call = (kind, fields = {}) => hook(file, kind, { sessionId: "session-a", ...fields });
  return { file, user, agent, call };
}

function complete(agent) {
  agent({ op: "plan", todos: ["Investigate", { title: "Demonstrate", depends_on: ["t1"] }] });
  agent({ op: "todo", id: "t1", status: "done", evidence: "Read the implementation" });
  agent({ op: "todo", id: "t2", status: "done", evidence: "Demo runs" });
}

test("review gates outcomes, not individual tools; acceptance is human-only", (t) => {
  const { file, user, agent, call } = fixture(t);
  complete(agent);
  assert.deepEqual(call("pre", { toolName: "edit", toolArgs: { path: "demo.js" } }), {});
  assert.throws(() => agent({ op: "ready", summary: "Done" }), /running jobs/);
  call("post", { toolName: "edit", toolArgs: { path: "demo.js" }, toolResult: { textResultForLlm: "Edited" } });
  agent({ op: "ready", summary: "Research and demo ready", artifacts: ["demo.js"] });
  assert.equal(call("pre", { toolName: "bash", toolArgs: { command: "touch ahead" } }).permissionDecision, "deny");
  assert.deepEqual(call("pre", { toolName: "bash", toolArgs: { command: 'node "$NVIM_WORKFLOW_RUNTIME" get' } }), {});
  assert.throws(() => agent({ op: "accept" }), /awaiting_review/);
  const state = read(file);
  assert.throws(() => user({ op: "accept", revision: state.revision - 1 }), /changed/);
  user({ op: "accept", revision: state.revision });
  assert.equal(current(read(file)).status, "accepted");
  user({ op: "next", title: "Now implement the ticket" });
  assert.equal(read(file).units.length, 2);
  assert.equal(current(read(file)).status, "planning", "A new unit starts by talking, not working");
  assert.throws(() => agent({ op: "plan", unit_id: "u1", todos: ["Late old update"] }), /Stale work unit/);
});

test("todo prerequisites, dependency validation and evidence are enforced", (t) => {
  const { file, agent } = fixture(t);
  assert.throws(() => agent({ op: "plan", todos: [{ title: "Cycle", depends_on: ["t1"] }] }), /cycle/);
  assert.throws(() => agent({ op: "plan", todos: [{ title: "Missing", depends_on: ["t9"] }] }), /Unknown/);
  agent({ op: "plan", todos: ["Research", { title: "Demo", depends_on: ["t1"] }] });
  assert.throws(() => agent({ op: "todo", id: "t2", status: "running" }), /prerequisite/);
  assert.throws(() => agent({ op: "todo", id: "t1", status: "done" }), /evidence/);
  agent({ op: "todo", id: "t1", status: "done", evidence: "Sources read" });
  agent({ op: "todo", id: "t2", status: "running" });
  assert.throws(() => agent({ op: "todo", id: "t1", status: "pending" }), /dependent/);
  assert.equal(current(read(file)).todos[0].status, "done");
});

test("required checks use actual hook output and current-attempt success", (t) => {
  const { file, user, agent, call } = fixture(t);
  agent({ op: "plan", todos: ["Change"], required_checks: ["node --test"] });
  agent({ op: "todo", id: "t1", status: "done", evidence: "Changed the implementation" });
  assert.throws(() => agent({ op: "ready", summary: "Done" }), /successful observed check/);
  const input = { toolName: "bash", toolArgs: { command: "node --test" } };
  call("pre", input);
  call("post", { ...input, toolResult: { textResultForLlm: "stdout says exit code 0\n<shellId: tests completed with exit code 1>" } });
  assert.equal(current(read(file)).checks.at(-1).exit_code, 1, "Stdout must not forge success");
  assert.throws(() => agent({ op: "ready", summary: "Done" }), /successful observed check/);
  call("pre", input);
  call("post", { ...input, toolResult: { textResultForLlm: "<shellId: tests completed with exit code 0>" } });
  call("pre", input);
  call("failure", { ...input, error: "Tool was interrupted" });
  assert.throws(() => agent({ op: "ready", summary: "Done" }), /successful observed check/);
  call("pre", input);
  call("post", { ...input, toolResult: { textResultForLlm: "<shellId: tests completed with exit code 0>" } });
  agent({ op: "ready", summary: "Checks pass" });
  user({ op: "revise", feedback: "Include the edge case" });
  assert.equal(current(read(file)).attempt, 2);
  assert.equal(current(read(file)).status, "planning", "Declining returns to planning");
  assert.throws(() => agent({ op: "todo", attempt: 1, id: "t1", status: "done", evidence: "Old job" }), /Stale/);
  agent({ op: "plan", todos: ["Change"], required_checks: ["node --test"] });
  agent({ op: "todo", id: "t1", status: "done", evidence: "Edge case included" });
  assert.throws(() => agent({ op: "ready", summary: "Done again" }), /successful observed check/);
});

test("asynchronous shell validation only counts after its actual completion", (t) => {
  const { agent, call } = fixture(t);
  agent({ op: "plan", todos: ["Validate"], required_checks: ["node --test"] });
  agent({ op: "todo", id: "t1", status: "done", evidence: "Changes complete" });
  const start = { toolName: "bash", toolArgs: { command: "node --test", mode: "async" } };
  call("pre", start);
  call("post", { ...start, toolResult: { textResultForLlm: "<shellId: async-tests running>" } });
  assert.throws(() => agent({ op: "ready", summary: "Done" }), /successful observed check/);
  const collect = { toolName: "read_bash", toolArgs: { shellId: "async-tests" } };
  call("pre", collect);
  call("post", { ...collect, toolResult: { textResultForLlm: "Tests pass\n<shellId: async-tests completed with exit code 0>" } });
  agent({ op: "ready", summary: "Observed asynchronous tests pass" });
});

test("background completion must be collected; general-purpose works without stop hook", (t) => {
  const { file, agent, call } = fixture(t);
  complete(agent);
  const input = { toolName: "task", toolArgs: { mode: "background", name: "research" } };
  call("pre", input);
  call("post", { ...input, toolResult: { textResultForLlm: "Agent started in background with agent_id: child-123" } });
  assert.throws(() => agent({ op: "ready", summary: "Done" }), /running jobs/);
  const collect = { toolName: "read_agent", toolArgs: { agent_id: "child-123" } };
  call("pre", collect);
  call("post", { ...collect, toolResult: { textResultForLlm: "Agent is idle (waiting for messages). status: idle\nResult" } });
  agent({ op: "ready", summary: "Background result incorporated" });
  assert.equal(current(read(file)).jobs[0].collected, true);
});

test("a child finishing before its spawn result cannot bypass collection", (t) => {
  const { agent, call } = fixture(t);
  complete(agent);
  call("child-stop", { agentId: "fast-child", agentName: "task" });
  call("post", {
    toolName: "task", toolArgs: { mode: "background" },
    toolResult: { textResultForLlm: "agent_id: fast-child" },
  });
  assert.throws(() => agent({ op: "ready", summary: "Done" }), /running jobs/);
});

test("follow-up messages reactivate collected agents and require collecting their new results", (t) => {
  const { file, agent, call } = fixture(t);
  complete(agent);
  call("child-stop", { agentId: "worker", agentName: "task" });
  const input = { toolName: "write_agent", toolArgs: { agent_id: "worker", message: "Include the edge case" } };
  call("pre", input);
  call("post", { ...input, toolResult: { textResultForLlm: "Message delivered" } });
  assert.equal(current(read(file)).jobs[0].status, "running");
  assert.throws(() => agent({ op: "ready", summary: "Done" }), /running jobs/);
  const collect = { toolName: "read_agent", toolArgs: { agent_id: "worker", wait: true } };
  call("pre", collect);
  call("post", { ...collect, toolResult: { textResultForLlm: "Agent is idle. status: idle\nEdge case addressed" } });
  agent({ op: "ready", summary: "New result collected" });
});

test("clarification pauses work and only a human answer resumes it", (t) => {
  const { file, user, agent, call } = fixture(t, { working: true });
  agent({ op: "decision", question: "Educational compiler from scratch, or production wrapper?" });
  assert.equal(call("pre", { toolName: "edit" }).permissionDecision, "deny");
  assert.throws(() => agent({ op: "plan", todos: ["Guess"] }), /needs_decision/);
  user({ op: "answer", feedback: "From scratch, educational, target x86-64" });
  assert.equal(current(read(file)).status, "running");
  assert.deepEqual(call("pre", { toolName: "edit" }), {});
});

test("forgotten state gets only one continuation, then a visible pause", (t) => {
  const { file, call } = fixture(t, { working: true });
  assert.equal(call("stop").decision, "block");
  assert.deepEqual(call("stop", { stop_hook_active: true }), {});
  assert.equal(current(read(file)).status, "paused");
  assert.equal(call("pre", { toolName: "bash" }).permissionDecision, "deny");
});

test("sessions cannot share a workflow accidentally, and live runtimes cannot be recovered", (t) => {
  const { user, call } = fixture(t);
  call("start");
  assert.throws(() => call("pre", { sessionId: "another-chat", toolName: "bash" }), /another Copilot session/);
  assert.throws(() => user({ op: "recover" }), /still running/);
});

test("recovery clears abandoned leases, preserves session history and starts a fresh attempt", (t) => {
  const { file, user, call } = fixture(t, { working: true });
  call("start");
  transact(file, (state) => {
    state.runtime_pid = 2147483647;
    current(state).inflight = { abandoned: 1 };
    current(state).jobs.push({ id: "abandoned", name: "worker", status: "running", collected: false });
    return state;
  });
  user({ op: "recover" });
  assert.equal(current(read(file)).status, "paused");
  assert.deepEqual(current(read(file)).inflight, {});
  assert.equal(current(read(file)).jobs[0].status, "cancelled");
  user({ op: "resume" });
  assert.equal(current(read(file)).attempt, 2);
  call("start", { sessionId: "session-b" });
  assert.deepEqual(read(file).session_ids, ["session-a", "session-b"]);
});

test("batched preToolUse calls are leased by tool call id and released by post hooks", (t) => {
  const { file, call } = fixture(t, { working: true });
  const calls = [
    { id: "c1", name: "io-sooperset-mcp-atlassian-jira_get_issue", args: { issue_key: "A-1" } },
    { id: "c2", name: "bash", args: { command: 'node "$NVIM_WORKFLOW_RUNTIME" get' } },
    { id: "c3", name: "bash", args: { command: "ls" } },
  ];
  assert.deepEqual(call("pre", { toolCalls: calls }), {});
  assert.equal(Object.keys(current(read(file)).inflight).length, 2);
  call("post", { toolCallId: "c1", toolName: "io-sooperset-mcp-atlassian-jira_get_issue", toolArgs: { issue_key: "A-1" }, toolResult: { textResultForLlm: "ok" } });
  call("post", { toolCallId: "c3", toolName: "bash", toolArgs: { command: "ls" }, toolResult: { textResultForLlm: "ok" } });
  assert.deepEqual(current(read(file)).inflight, {});
});

test("controller commands do not count themselves as outstanding tools or grant approval", (t) => {
  const { file } = fixture(t);
  const args = { toolName: "bash", toolArgs: {
    command: 'node "$NVIM_WORKFLOW_RUNTIME" update <<\'WORKFLOW\'\n{"op":"plan","attempt":1,"todos":["Do work"]}\nWORKFLOW',
  } };
  assert.equal(controllerCommand(args), "update");
  hook(file, "pre", { sessionId: "session-a", ...args });
  assert.deepEqual(current(read(file)).inflight, {});
  hook(file, "post", { sessionId: "session-a", ...args });
  assert.equal(read(file).events.some((item) => item.type === "tool_failed"), false);
  const rejected = spawnSync(process.execPath, [runtime, "update"], {
    env: { ...process.env, NVIM_WORKFLOW_FILE: file },
    input: '{"op":"accept","unit_id":"u1","attempt":1}', encoding: "utf8",
  });
  assert.equal(rejected.status, 1);
  assert.match(rejected.stderr, /human review actions/);
  const forged = spawnSync(process.execPath, [runtime, "update"], {
    env: { ...process.env, NVIM_WORKFLOW_FILE: file },
    input: '{"op":"check","unit_id":"u1","attempt":1,"exit_code":0}', encoding: "utf8",
  });
  assert.equal(forged.status, 1);
  assert.match(forged.stderr, /Unknown agent action/);
});

test("corruption is not treated as normal chat; command hooks fail closed", (t) => {
  const { file } = fixture(t);
  fs.writeFileSync(file, "{broken");
  assert.throws(() => hook(file, "pre", { sessionId: "session-a", toolName: "bash" }), /JSON/);
  const result = spawnSync(process.execPath, [runtime, "hook", "pre"], {
    env: { ...process.env, NVIM_WORKFLOW_FILE: file }, input: '{"sessionId":"a","toolName":"bash"}',
    encoding: "utf8",
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /nvim-workflow/);
  fs.writeFileSync(file, '{"version":1,"units":[],"active":0}');
  assert.throws(() => read(file), /corrupt workflow/);
});

test("a missing opted-in workflow fails closed rather than becoming normal chat", (t) => {
  const { file } = fixture(t);
  fs.unlinkSync(file);
  const result = spawnSync(process.execPath, [runtime, "hook", "pre"], {
    env: { ...process.env, NVIM_WORKFLOW_FILE: file, NVIM_WORKFLOW_REQUIRED: "1" },
    input: '{"sessionId":"a","toolName":"bash"}', encoding: "utf8",
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /workflow state is missing/);
});
test("the runtime also runs through a symlinked Neovim config directory", (t) => {
  const { file } = fixture(t);
  const link = path.join(path.dirname(file), "runtime-link.mjs");
  fs.symlinkSync(runtime, link);
  const result = spawnSync(process.execPath, [link, "get"], {
    env: { ...process.env, NVIM_WORKFLOW_FILE: file }, encoding: "utf8",
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout).goal, "Research and demo together");
});

test("state getters and stop notifications do not invalidate the reviewed revision", (t) => {
  const { file, agent, call } = fixture(t);
  complete(agent);
  call("start");
  agent({ op: "ready", summary: "Review this exact revision" });
  const before = read(file).revision;
  const input = { toolName: "bash", toolArgs: { command: 'node "$NVIM_WORKFLOW_RUNTIME" get' } };
  call("pre", input);
  call("post", input);
  call("stop");
  assert.equal(read(file).revision, before);
});

test("parallel processes preserve atomic state and all events", async (t) => {
  const { file } = fixture(t);
  const children = Array.from({ length: 8 }, () => new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [runtime, "hook", "start"], {
      env: { ...process.env, NVIM_WORKFLOW_FILE: file }, stdio: ["pipe", "ignore", "pipe"],
    });
    let error = "";
    child.stderr.on("data", (chunk) => { error += chunk; });
    child.on("error", reject);
    child.on("exit", (code) => code === 0 ? resolve() : reject(new Error(error)));
    child.stdin.end('{"sessionId":"session-a"}');
  }));
  await Promise.all(children);
  assert.equal(read(file).events.filter((item) => item.type === "connected").length, 8);
  assert.equal(fs.existsSync(`${file}.lock`), false);
});

test("planning is plain chat; a plan only runs after the human approves it", (t) => {
  const { file, user, agent, call } = fixture(t);
  assert.equal(current(read(file)).status, "planning");
  assert.deepEqual(call("pre", { toolName: "edit", toolArgs: { path: "a.js" } }), {}, "Planning keeps normal tools");
  call("post", { toolName: "edit", toolArgs: { path: "a.js" }, toolResult: { textResultForLlm: "Edited" } });
  assert.deepEqual(call("stop"), {}, "Ending a planning turn is just chatting");
  assert.throws(() => agent({ op: "todo", id: "t1", status: "running" }), /not allowed while the unit is planning/);
  assert.throws(() => agent({ op: "ready", summary: "Done" }), /not allowed while the unit is planning/);
  assert.throws(
    () => transact(file, (state) => agentAction(state, { op: "plan", unit_id: "u1", attempt: 1, todos: ["Too early"] })),
    /problem/,
  );
  assert.throws(() => agent({ op: "problem", problem: " " }), /Problem/);
  agent({ op: "problem", title: "Fix the launcher env", problem: "Sessions start without tokens" });
  assert.equal(current(read(file)).title, "Fix the launcher env");
  agent({ op: "plan", hold: true, todos: ["Compare env"], commands: ["git commit -m fix"] });
  assert.equal(current(read(file)).status, "awaiting_plan");
  assert.equal(call("pre", { toolName: "bash", toolArgs: { command: "touch x" } }).permissionDecision, "deny");
  assert.throws(() => user({ op: "approve", revision: 0 }), /changed/);
  user({ op: "approve", revision: read(file).revision });
  const unit = current(read(file));
  assert.equal(unit.status, "running");
  assert.equal(unit.approved_attempt, unit.attempt);
  assert.deepEqual(unit.plan_commands, ["git commit -m fix"]);
  assert.throws(() => agent({ op: "plan", todos: ["Replace the approved plan"] }), /not allowed while the unit is running/);
});

test("declining a plan or a result goes back to planning; resuming keeps an approval", (t) => {
  const { file, user, agent } = fixture(t);
  agent({ op: "plan", hold: true, todos: ["Wrong approach"] });
  user({ op: "revise", feedback: "That is not what I meant" });
  let unit = current(read(file));
  assert.deepEqual([unit.status, unit.attempt, unit.todos.length], ["planning", 2, 0]);
  assert.notEqual(unit.approved_attempt, unit.attempt);
  agent({ op: "plan", todos: ["Right approach"] });
  unit = current(read(file));
  assert.equal(unit.status, "running");
  transact(file, (state) => {
    current(state).status = "paused";
    return state;
  });
  user({ op: "resume" });
  unit = current(read(file));
  assert.deepEqual([unit.status, unit.approved_attempt === unit.attempt], ["running", true]);
});

test('explicit check runner records actual success and failure', (t) => {
  const { file, agent } = fixture(t);
  const success = 'node -e "process.exit(0)"';
  const failure = 'node -e "process.exit(7)"';
  agent({ op: 'plan', todos: ['Validate'], required_checks: [success, failure] });
  for (const [command, code] of [[success, 0], [failure, 7]]) {
    const result = spawnSync(process.execPath, [fileURLToPath(new URL('./check.mjs', import.meta.url)), command], {
      env: { ...process.env, NVIM_WORKFLOW_FILE: file }, encoding: 'utf8',
    });
    assert.equal(result.status, code, result.stderr);
    assert.equal(current(read(file)).checks.at(-1).exit_code, code);
    assert.equal(current(read(file)).checks.at(-1).command, command);
    assert.deepEqual(current(read(file)).inflight, {});
  }
});
