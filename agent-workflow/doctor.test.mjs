import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { checkDependencies, versionAtLeast } from "./doctor.mjs";

test("version checks use the executable version, including Neovim's minimum", () => {
  assert.equal(versionAtLeast("NVIM v0.10.4\nBuild type: Release", "0.11.0"), false);
  assert.equal(versionAtLeast("NVIM v0.11.5", "0.11.0"), true);
  assert.equal(versionAtLeast("v22.1.0", "20.0.0"), true);
  assert.equal(versionAtLeast("unknown", "20.0.0"), false);
});

test("doctor handles alternatives, Mason-only programs, failed probes and agent-only scope", (t) => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "dependency-doctor-"));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  const bin = path.join(home, "bin"); fs.mkdirSync(bin);
  const mason = path.join(home, "data", "test-nvim", "mason", "bin");
  fs.mkdirSync(mason, { recursive: true });
  const executable = (dir, name, body) => fs.writeFileSync(path.join(dir, name), `#!/bin/sh\n${body}\n`, { mode: 0o755 });
  executable(bin, "doctor-fallback", "exit 0");
  executable(bin, "doctor-old", "echo 'NVIM v0.10.4'");
  executable(bin, "doctor-broken", "exit 1");
  executable(mason, "doctor-language-server", "exit 0");
  const manifest = {
    runtime: [{ command: "doctor-broken", probe: ["--version"] }],
    neovim: [
      { anyOf: ["doctor-missing", "doctor-fallback"] },
      { command: "doctor-old", probe: ["--version"], minimumVersion: "0.11.0" },
    ],
    languageServers: [{ command: "doctor-language-server", managedBy: "mason" }, { command: "doctor-never-installed", managedBy: "mason" }],
  };
  const env = { ...process.env, HOME: home, XDG_DATA_HOME: path.join(home, "data"), NVIM_APPNAME: "test-nvim", PATH: `${bin}:/usr/bin:/bin` };
  const checks = checkDependencies({ manifest, env });
  assert.equal(checks[0].reason, "executable probe failed");
  assert.equal(checks[1].command, "doctor-fallback");
  assert.equal(checks[1].available, true);
  assert.equal(checks[2].reason, "requires version 0.11.0+");
  assert.equal(checks[3].resolved, path.join(mason, "doctor-language-server"));
  assert.equal(checks[3].available, true);
  assert.equal(checks[4].available, false);
  assert.deepEqual(checkDependencies({ manifest, env, agentsOnly: true }).map((item) => item.group), ["runtime"]);
});
