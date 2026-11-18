import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { normalisePayload, writeTargets } from "./write-gate.mjs";

const hook = fileURLToPath(new URL("./write-gate.mjs", import.meta.url));
const phrase = "for the love of everything, please edit, please help me";
function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "gate-adapter-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const repo = path.join(root, "repo");
  fs.mkdirSync(path.join(repo, ".git"), { recursive: true });
  const state = path.join(root, "state");
  fs.mkdirSync(state);
  fs.writeFileSync(path.join(state, "mode"), "deny");
  const env = { ...process.env, WRITE_GATE_HOME: state, NVIM_WORKFLOW_FILE: "", NVIM: "", DISPLAY: "", WAYLAND_DISPLAY: "" };
  function run(agent, kind, payload, extraEnv = {}) {
    const child = spawnSync(process.execPath, [hook, kind, `--agent=${agent}`], {
      input: JSON.stringify({ cwd: repo, ...payload }), env: { ...env, ...extraEnv }, encoding: "utf8", timeout: 12000,
    });
    assert.equal(child.status, 0, child.stderr);
    return child.stdout.trim() ? JSON.parse(child.stdout) : null;
  }
  return { root, repo, run };
}

test("native Codex and Claude denials have the required envelope; Copilot stays compatible", (t) => {
  const { run } = fixture(t);
  for (const agent of ["codex", "claude", "copilot"]) {
    const output = run(agent, "tool", { tool_name: "Bash", tool_input: { command: "touch gated.txt" } });
    const decision = agent === "copilot" ? output : output.hookSpecificOutput;
    assert.equal(decision.permissionDecision, "deny");
    if (agent !== "copilot") assert.equal(decision.hookEventName, "PreToolUse");
  }
});

test("approval stays inside its agent/session and is revoked on the next prompt", (t) => {
  const { run } = fixture(t);
  const tool = { tool_name: "Write", tool_input: { file_path: "gated.txt", content: "test" }, session_id: "one" };
  run("codex", "prompt", { prompt: phrase, session_id: "one" });
  assert.equal(run("codex", "tool", tool), null);
  assert.equal(run("claude", "tool", tool).hookSpecificOutput.permissionDecision, "deny");
  assert.equal(run("codex", "tool", { ...tool, session_id: "two" }).hookSpecificOutput.permissionDecision, "deny");
  run("codex", "prompt", { prompt: "next task", session_id: "one" });
  assert.equal(run("codex", "tool", tool).hookSpecificOutput.permissionDecision, "deny");
});

test("Codex invokes Zenity and requires the correct phrase", (t) => {
  const { root, run } = fixture(t);
  const bin = path.join(root, "bin");
  fs.mkdirSync(bin);
  const calls = path.join(root, "zenity-calls.jsonl");
  fs.writeFileSync(path.join(bin, "zenity"), `#!${process.execPath}\n` +
    'require("fs").appendFileSync(process.env.CALLS, JSON.stringify(process.argv.slice(2))+"\\n");\n' +
    'process.stdout.write(process.env.ANSWER || "");\n', { mode: 0o755 });
  const env = { DISPLAY: ":test", PATH: `${bin}:${process.env.PATH}`, CALLS: calls };
  const payload = { session_id: "codex-session", tool_name: "apply_patch", tool_input: {
    command: "*** Begin Patch\n*** Add File: gated.txt\n+hello\n*** End Patch",
  } };
  assert.equal(run("codex", "tool", payload, { ...env, ANSWER: "wrong" }).hookSpecificOutput.permissionDecision, "deny");
  assert.equal(run("codex", "tool", payload, { ...env, ANSWER: phrase }), null);
  const invocations = fs.readFileSync(calls, "utf8").trim().split("\n").map(JSON.parse);
  assert.equal(invocations.length, 2);
  assert.ok(invocations.every((args) => args.includes("--entry") && args.includes("--title=Write gate")));
});

test("ACP raw inputs and Codex command aliases are normalised", (t) => {
  const { repo } = fixture(t);
  for (const payload of [
    { tool_name: "exec_command", tool_input: { cmd: "touch gated.txt" } },
    { toolCall: { name: "Write", rawInput: { file_path: "gated.txt", content: "x" } } },
  ]) {
    const call = normalisePayload({ cwd: repo, ...payload });
    assert.deepEqual(writeTargets(call.toolName, call.toolArgs, call.cwd), [repo]);
  }
});

test("Copilot pre-tool batches inspect all calls", (t) => {
  const { run } = fixture(t);
  const output = run("copilot", "tool", { toolCalls: [
    { id: "read", name: "bash", args: { command: "ls" } },
    { id: "write", name: "create", args: { path: "gated.txt", file_text: "x" } },
  ] });
  assert.equal(output.permissionDecision, "deny");
});
