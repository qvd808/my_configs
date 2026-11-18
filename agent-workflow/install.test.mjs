import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const installer = fileURLToPath(new URL("./install.mjs", import.meta.url));
test("installer discovers skills, preserves unrelated settings, and is idempotent", (t) => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "agent-install-"));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  fs.symlinkSync(path.join(home, "missing-old-source"), path.join(home, ".agent"));
  fs.mkdirSync(path.join(home, ".claude"));
  fs.writeFileSync(path.join(home, ".claude", "settings.json"), JSON.stringify({
    model: "keep-my-model", hooks: { PreToolUse: [{ hooks: [{ type: "command", command: "echo existing" }] }] },
  }));
  const env = { ...process.env, HOME: home, CODEX_HOME: path.join(home, ".codex"), CLAUDE_CONFIG_DIR: path.join(home, ".claude") };
  const run = () => {
    const result = spawnSync(process.execPath, [installer, "--agents-only"], { env, encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
  };
  run();
  assert.ok(fs.lstatSync(path.join(home, ".agent")).isSymbolicLink());
  assert.equal(fs.readdirSync(home).filter((name) => name.startsWith(".agent.before-agent-workflow-")).length, 1);
  assert.ok(fs.existsSync(path.join(home, ".agent", "hooks", "write-gate.mjs")));
  assert.ok(fs.existsSync(path.join(home, ".agents", "skills", "cloudflare", "SKILL.md")));
  const settings = path.join(home, ".claude", "settings.json");
  const saved = fs.readFileSync(settings, "utf8");
  const value = JSON.parse(saved);
  assert.equal(value.model, "keep-my-model");
  assert.equal(value.hooks.PreToolUse[0].hooks[0].command, "echo existing");
  assert.match(value.hooks.PreToolUse[1].hooks[0].command, /--agent=claude/);
  const native = JSON.parse(fs.readFileSync(path.join(home, ".codex", "hooks.json")));
  assert.match(native.hooks.PreToolUse[0].hooks[0].command, /--agent=codex/);
  const copilot = JSON.parse(fs.readFileSync(path.join(home, ".copilot", "hooks", "write-gate.json")));
  assert.match(copilot.hooks.preToolUse[0].bash, /--agent=copilot/);
  run();
  assert.equal(fs.readFileSync(settings, "utf8"), saved);
  assert.equal(fs.readdirSync(path.join(home, ".claude")).filter((name) => name.includes("before-agent-workflow")).length, 1);
  assert.equal(fs.existsSync(path.join(home, ".config", "nvim")), false, "agents-only leaves editor config alone");
});
