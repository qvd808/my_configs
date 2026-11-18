import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";

function requireThat(condition, message) {
  if (!condition) throw new Error(message);
}

function text(value, name) {
  requireThat(typeof value === "string" && value.trim().length > 0, `${name} must not be empty`);
  return value.trim();
}

export function read(file) {
  try {
    const state = JSON.parse(fs.readFileSync(file, "utf8"));
    requireThat(state.version === 1 && Array.isArray(state.units) && Number.isInteger(state.active) &&
      state.units[state.active] && ["planning", "awaiting_plan", "running", "paused", "needs_decision", "awaiting_review", "accepted"]
        .includes(state.units[state.active].status), "Unsupported or corrupt workflow state");
    return state;
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw error;
  }
}

export function current(state) {
  const unit = state?.units[state.active];
  requireThat(unit, "No active work unit");
  return unit;
}

export function event(state, type, detail = "") {
  state.events.push({ time: new Date().toISOString(), type, unit: current(state).id, detail });
}

export function transact(file, update) {
  requireThat(file && path.isAbsolute(file), "An absolute workflow state path is required");
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const lock = `${file}.lock`;
  let owned = false;
  for (let attempt = 0; attempt < 100; attempt++) {
    try {
      const fd = fs.openSync(lock, "wx", 0o600);
      owned = true;
      try {
        fs.writeFileSync(fd, String(process.pid));
      } finally {
        fs.closeSync(fd);
      }
      break;
    } catch (error) {
      if (owned || error.code !== "EEXIST") throw error;
      try {
        const pid = Number(fs.readFileSync(lock, "utf8"));
        if (Number.isInteger(pid) && pid > 0) {
          try {
            process.kill(pid, 0);
          } catch (probeError) {
            if (probeError.code !== "ESRCH") throw probeError;
            fs.unlinkSync(lock);
          }
        }
      } catch (probeError) {
        if (probeError.code !== "ENOENT") throw probeError;
      }
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
    }
  }
  requireThat(owned, `Workflow is busy: ${file}`);
  const temp = `${file}.${process.pid}.${randomUUID()}.tmp`;
  try {
    const previous = read(file);
    const original = JSON.stringify(previous);
    const state = update(previous);
    if (JSON.stringify(state) === original) return state;
    state.revision = (state.revision ?? 0) + 1;
    state.updated_at = new Date().toISOString();
    const fd = fs.openSync(temp, "wx", 0o600);
    try {
      fs.writeFileSync(fd, `${JSON.stringify(state, null, 2)}\n`);
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    fs.renameSync(temp, file);
    return state;
  } finally {
    if (fs.existsSync(temp)) fs.unlinkSync(temp);
    fs.unlinkSync(lock);
  }
}

function newUnit(title, index) {
  return {
    id: `u${index + 1}`, title: text(title, "Outcome"), status: "planning", attempt: 1,
    problem: "", plan_commands: [], approved_attempt: 0,
    todos: [], required_checks: [], checks: [], jobs: [], inflight: {},
    summary: "", artifacts: [], decision: "",
  };
}

export function busy(unit) {
  return Object.values(unit.inflight).some((count) => count > 0) ||
    unit.jobs.some((job) => job.status === "running" || job.collected === false);
}

export function userAction(state, args) {
  if (args.op === "create") {
    requireThat(!state, "Workflow already exists");
    const goal = text(args.goal, "Goal");
    return {
      version: 1, id: randomUUID(), cwd: text(args.cwd, "Working directory"),
      goal, active: 0, units: [newUnit(goal, 0)], events: [], session_id: null, session_ids: [],
    };
  }
  const unit = current(state);
  if (args.op === "recover") {
    if (state.runtime_pid) {
      try {
        process.kill(state.runtime_pid, 0);
        throw new Error(`The previous Copilot process is still running (PID ${state.runtime_pid}); close that chat first`);
      } catch (error) {
        if (error.code !== "ESRCH") throw error;
      }
    }
    state.session_id = null;
    state.runtime_pid = null;
    unit.inflight = {};
    for (const job of unit.jobs) {
      if (job.status === "running") job.status = "cancelled";
      job.collected = true;
    }
    if (unit.status === "running") unit.status = "paused";
    event(state, "recovered", "Previous runtime exited; inspect changes before continuing");
    return state;
  }
  if (args.op === "pause") {
    if (unit.status === "running") {
      unit.status = "paused";
      event(state, "paused", args.reason ?? "Chat stopped");
    }
    return state;
  }
  requireThat(!busy(unit), "Work is still running; collect or cancel background jobs before reviewing");
  if (args.op === "accept") {
    requireThat(unit.status === "awaiting_review", "Only a submitted work unit can be accepted");
    requireThat(args.revision === state.revision, "Workflow changed; review its latest state before accepting");
    unit.status = "accepted";
    event(state, "accepted", unit.summary);
  } else if (args.op === "approve") {
    requireThat(unit.status === "awaiting_plan", "No plan is waiting for approval");
    requireThat(args.revision === state.revision, "Workflow changed; review its latest state before approving");
    unit.status = "running";
    unit.approved_attempt = unit.attempt;
    event(state, "approved", unit.problem);
  } else if (args.op === "next") {
    requireThat(unit.status === "accepted", "Accept the current outcome before starting another");
    state.active = state.units.length;
    state.units.push(newUnit(args.title, state.active));
    event(state, "started", args.title);
  } else if (args.op === "revise" || args.op === "answer" || args.op === "resume") {
    const allowed = {
      revise: ["awaiting_review", "awaiting_plan"],
      answer: ["needs_decision"],
      resume: ["paused", "running"],
    };
    requireThat(allowed[args.op].includes(unit.status), `Cannot ${args.op} a ${unit.status} unit`);
    const feedback = args.op === "resume" && !args.feedback
      ? "Continue the interrupted unit" : text(args.feedback, "Feedback");
    const wasApproved = unit.approved_attempt === unit.attempt;
    if (args.op !== "answer") {
      unit.attempt++;
      unit.summary = "";
      if (args.op === "revise") {
        unit.todos = [];
        unit.plan_commands = [];
      }
    }
    // Declining always returns to planning (plain chat, normal write gate); a plan approval survives only a resume or answer
    if (args.op !== "revise" && wasApproved) unit.approved_attempt = unit.attempt;
    unit.status = args.op !== "revise" && wasApproved ? "running" : "planning";
    unit.decision = "";
    event(state, args.op, feedback);
  } else {
    throw new Error(`Unknown user action: ${args.op}`);
  }
  return state;
}

function strings(value, name) {
  requireThat(Array.isArray(value), `${name} must be a list`);
  return value.map((item) => text(item, name));
}

function validateTodos(todos) {
  const visited = new Set();
  const visiting = new Set();
  function visit(todo) {
    requireThat(!visiting.has(todo.id), "Todo dependencies contain a cycle");
    if (visited.has(todo.id)) return;
    visiting.add(todo.id);
    for (const id of todo.depends_on) {
      const dependency = todos.find((item) => item.id === id);
      requireThat(dependency, `Unknown todo dependency: ${id}`);
      visit(dependency);
    }
    visiting.delete(todo.id);
    visited.add(todo.id);
  }
  todos.forEach(visit);
}

export function agentAction(state, args) {
  const unit = current(state);
  requireThat(unit.status === "running" || unit.status === "planning", `Unit is ${unit.status}; wait for the user in <leader>ac`);
  requireThat(args.unit_id === unit.id, "Stale work unit; read controller state before updating it");
  requireThat(args.attempt === unit.attempt, "Stale attempt; call workflow_get before changing state");
  const allowed = {
    planning: ["problem", "plan", "decision"],
    running: ["add_todo", "todo", "decision", "ready"],
  }[unit.status];
  const known = ["problem", "plan", "add_todo", "todo", "decision", "ready"];
  requireThat(!known.includes(args.op) || allowed.includes(args.op),
    `${args.op} is not allowed while the unit is ${unit.status}` +
    (unit.status === "planning" ? "; record the problem, then propose a plan for the user to approve" : ""));
  if (args.op === "problem") {
    unit.problem = text(args.problem, "Problem");
    if (args.title) unit.title = text(args.title, "Title");
  } else if (args.op === "plan") {
    requireThat(unit.problem, "Record the agreed problem with a problem update before proposing a plan");
    requireThat(!busy(unit), "Collect or cancel running jobs/tools before proposing the plan");
    requireThat(unit.todos.length === 0, "Plan already exists; use add_todo for newly discovered work");
    requireThat(Array.isArray(args.todos) && args.todos.length > 0, "Plan must contain at least one todo");
    unit.todos = args.todos.map((todo, i) => ({
      id: `t${i + 1}`, title: text(typeof todo === "string" ? todo : todo.title, "Todo"),
      depends_on: strings(typeof todo === "string" ? [] : todo.depends_on ?? [], "Dependencies"),
      status: "pending", evidence: "",
    }));
    validateTodos(unit.todos);
    unit.required_checks = strings(args.required_checks ?? [], "Required checks");
    unit.plan_commands = strings(args.commands ?? [], "Commands");
    unit.status = "awaiting_plan";
  } else if (args.op === "add_todo") {
    unit.todos.push({
      id: `t${unit.todos.length + 1}`, title: text(args.title, "Todo"), status: "pending", evidence: "",
      depends_on: strings(args.depends_on ?? [], "Dependencies"),
    });
    validateTodos(unit.todos);
    for (const command of strings(args.required_checks ?? [], "Required checks")) {
      if (!unit.required_checks.includes(command)) unit.required_checks.push(command);
    }
  } else if (args.op === "todo") {
    const todo = unit.todos.find((item) => item.id === args.id);
    requireThat(todo, "Unknown todo");
    requireThat(["pending", "running", "done"].includes(args.status), "Invalid todo status");
    if (args.status !== "pending") {
      requireThat(todo.depends_on.every((id) => unit.todos.find((item) => item.id === id).status === "done"),
        "Complete prerequisite todos first");
    }
    if (args.status !== "done") {
      requireThat(!unit.todos.some((item) => item.depends_on.includes(todo.id) && item.status !== "pending"),
        "Reset dependent todos first");
    }
    todo.status = args.status;
    todo.evidence = args.status === "done" ? text(args.evidence, "Completion evidence") : "";
  } else if (args.op === "decision" || args.op === "ready") {
    requireThat(!busy(unit), "Collect or cancel running jobs/tools before pausing this unit");
    if (args.op === "decision") {
      unit.decision = text(args.question, "Question");
      unit.status = "needs_decision";
    } else {
      requireThat(unit.todos.length > 0 && unit.todos.every((todo) => todo.status === "done"),
        "Complete the unit's todos first");
      for (const command of unit.required_checks) {
        const latest = unit.checks.findLast((check) => check.command === command && check.attempt === unit.attempt);
        requireThat(latest?.exit_code === 0, `No successful observed check this attempt: ${command}`);
      }
      unit.summary = text(args.summary, "Review summary");
      unit.artifacts = strings(args.artifacts ?? [], "Artifacts");
      unit.status = "awaiting_review";
    }
  } else {
    throw new Error(`Unknown agent action: ${args.op}; human review actions are not agent tools`);
  }
  event(state, args.op, args.summary ?? args.question ?? args.problem ?? args.id ?? args.title ?? "");
  return state;
}
