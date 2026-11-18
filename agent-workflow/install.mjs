#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { reportDependencies } from "./doctor.mjs";

const source = path.dirname(fileURLToPath(import.meta.url));
const repo = path.dirname(source);
const home = os.homedir();
const stamp = `${Date.now()}-${process.pid}`;
const canonical = path.join(home, ".agent");
const dependencyOptions = { agentsOnly: process.argv.includes("--agents-only") };
for (const flag of process.argv.slice(2)) {
  if (!["--agents-only", "--check", "--help"].includes(flag)) throw new Error(`Unknown option: ${flag}`);
}
if (process.argv.includes("--help")) {
  console.log("Usage: ./init.sh [--agents-only | --check]\nInstalls shared agent links and hook registrations, with backups.");
  process.exit(0);
}

function backup(file) {
  const saved = `${file}.before-agent-workflow-${stamp}`;
  fs.copyFileSync(file, saved);
  // Settings may contain account-specific values; don't widen their permissions.
  fs.chmodSync(saved, fs.statSync(file).mode & 0o777);
  console.log(`Backup: ${saved}`);
}

function link(target, file) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  let existing;
  try { existing = fs.lstatSync(file); } catch (e) { if (e.code !== "ENOENT") throw e; }
  if (existing?.isSymbolicLink() && path.resolve(path.dirname(file), fs.readlinkSync(file)) === target) return;
  // ~/.agents may already alias ~/.agent. Never replace the source through
  // another name for the same file (which would create a self-referencing link).
  if (existing && fs.existsSync(file) && fs.existsSync(target) && fs.realpathSync(file) === fs.realpathSync(target)) return;
  if (existing) {
    const saved = `${file}.before-agent-workflow-${stamp}`;
    fs.renameSync(file, saved);
    console.log(`Backup: ${saved}`);
  }
  fs.symlinkSync(target, file);
  console.log(`Linked: ${file} -> ${target}`);
}

function writeJson(file, update) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const exists = fs.existsSync(file);
  const old = exists ? fs.readFileSync(file, "utf8") : "{}";
  const value = JSON.parse(old); // Abort rather than overwrite malformed user config.
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`Expected JSON object: ${file}`);
  const text = JSON.stringify(update(value), null, 2) + "\n";
  if (text === old) return;
  if (exists) backup(file);
  fs.writeFileSync(file, text, { mode: 0o600 });
  console.log(`Configured: ${file}`);
}

// Each agent has its own registration schema; every command uses the same gate.
const hookPath = '"$HOME/.agent/hooks/write-gate.mjs"';
function nativeHooks(agent) {
  return Object.fromEntries([
    ["UserPromptSubmit", "prompt", 10], ["PreToolUse", "tool", 100], ["PostToolUse", "done", 10],
  ].map(([event, mode, timeout]) => [event, [{
    ...(event === "UserPromptSubmit" ? {} : { matcher: ".*" }),
    hooks: [{ type: "command", command: `node ${hookPath} ${mode} --agent=${agent}`, timeout }],
  }]]));
}

function mergeNative(value, agent) {
  value.hooks ??= {};
  for (const [event, groups] of Object.entries(nativeHooks(agent))) {
    const previous = (value.hooks[event] ?? []).map((group) => ({ ...group,
      hooks: (group.hooks ?? []).filter((hook) => !hook.command?.includes("write-gate.mjs")),
    })).filter((group) => group.hooks.length);
    value.hooks[event] = [...previous, ...groups];
  }
  return value;
}

if (process.argv.includes("--check")) {
  process.exitCode = reportDependencies(dependencyOptions) ? 0 : 1;
} else {
  // Keep the source in Git. ~/.agent is a stable entry point, not another copy.
  link(path.join(source, ".agents"), canonical);
  link(path.join(canonical, "hooks", "write-gate.mjs"), path.join(home, ".agents", "hooks", "write-gate.mjs"));
  const codex = process.env.CODEX_HOME || path.join(home, ".codex");
  const claude = process.env.CLAUDE_CONFIG_DIR || path.join(home, ".claude");
  for (const entry of fs.readdirSync(path.join(source, ".agents", "skills"), { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    for (const directory of [path.join(home, ".agents"), claude, path.join(home, ".copilot")]) {
      link(path.join(canonical, "skills", entry.name), path.join(directory, "skills", entry.name));
    }
  }
  writeJson(path.join(codex, "hooks.json"), (value) => mergeNative(value, "codex"));
  writeJson(path.join(claude, "settings.json"), (value) => mergeNative(value, "claude"));
  writeJson(path.join(home, ".copilot", "hooks", "write-gate.json"), (value) => {
    const template = JSON.parse(fs.readFileSync(path.join(source, ".copilot", "hooks", "write-gate.json"), "utf8"));
    value.version = 1;
    value.hooks ??= {};
    for (const [event, hooks] of Object.entries(template.hooks)) {
      value.hooks[event] = [...(value.hooks[event] ?? []).filter((hook) => !hook.bash?.includes("write-gate.mjs")), ...hooks];
    }
    return value;
  });
  if (!process.argv.includes("--agents-only")) {
    link(path.join(repo, "nvim"), path.join(home, ".config", "nvim"));
    link(path.join(repo, "tmux_configs", ".tmux.conf"), path.join(home, ".tmux.conf"));
  }
  if (!reportDependencies(dependencyOptions)) console.log("Install the missing required dependencies above; Zenity dialogs need a working desktop display.");
  console.log("Shared workflow installed. Restart agents to load hooks; existing gate mode is unchanged (new installs default to log).");
}
