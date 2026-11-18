#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";

export function versionAtLeast(output, minimum) {
  const match = output.match(/\b(?:v)?(\d+)\.(\d+)(?:\.(\d+))?/);
  if (!match) return false;
  const actual = match.slice(1).map((part) => Number(part ?? 0));
  const wanted = minimum.split(".").map(Number);
  for (let i = 0; i < 3; i++) {
    if (actual[i] !== (wanted[i] ?? 0)) return actual[i] > (wanted[i] ?? 0);
  }
  return true;
}

export function checkDependencies({
  manifest = JSON.parse(fs.readFileSync(new URL("./dependencies.json", import.meta.url), "utf8")),
  env = process.env, agentsOnly = false,
} = {}) {
  const mason = path.join(env.XDG_DATA_HOME || path.join(env.HOME || os.homedir(), ".local", "share"),
    env.NVIM_APPNAME || "nvim", "mason", "bin");
  return Object.entries(manifest).filter(([group]) => !agentsOnly || !["neovim", "neovimOptional", "languageServers"].includes(group))
    .flatMap(([group, entries]) => entries.map((item) => {
      const commands = item.anyOf || [item.command];
      const searchEnv = item.managedBy === "mason" ? { ...env, PATH: `${env.PATH || ""}${path.delimiter}${mason}` } : env;
      let resolved, command;
      for (const candidate of commands) {
        const found = spawnSync("sh", ["-c", 'command -v "$1"', "sh", candidate], { env: searchEnv, encoding: "utf8" });
        if (found.status === 0) { resolved = found.stdout.trim(); command = candidate; break; }
      }
      let available = Boolean(resolved), reason;
      if (!available) reason = "not found";
      else if (item.probe) {
        const probe = spawnSync(resolved, item.probe, { env: searchEnv, encoding: "utf8", timeout: 3000, maxBuffer: 256 * 1024 });
        if (probe.status !== 0) { available = false; reason = "executable probe failed"; }
        else if (item.minimumVersion && !versionAtLeast(probe.stdout + probe.stderr, item.minimumVersion)) {
          available = false; reason = `requires version ${item.minimumVersion}+`;
        }
      }
      return { ...item, group, command: command || commands.join(" or "), resolved, available, reason };
    }));
}

export function reportDependencies(options = {}) {
  const checks = checkDependencies(options);
  for (const item of checks) {
    console.log(`${item.available ? "OK" : "MISSING"} ${item.command} (${item.group}): ${item.purpose}${item.reason ? ` — ${item.reason}` : ""}`);
    if (item.resolved && item.managedBy === "mason") console.log(`  ${item.resolved}`);
    if (!item.available && item.install) console.log(`  ${item.install}`);
  }
  console.log(`Display: ${process.env.DISPLAY || process.env.WAYLAND_DISPLAY || "none — GUI approval unavailable"}`);
  return checks.filter((item) => ["runtime", "neovim"].includes(item.group)).every((item) => item.available);
}

if (process.argv[1] && import.meta.url === pathToFileURL(fs.realpathSync(process.argv[1])).href) {
  process.exitCode = reportDependencies({ agentsOnly: process.argv.includes("--agents-only") }) ? 0 : 1;
}
