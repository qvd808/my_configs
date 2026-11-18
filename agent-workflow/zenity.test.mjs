// Opt-in integration test: opens a real Zenity window on a private X display.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { once } from "node:events";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { createServer } from "node:http";
import { randomBytes } from "node:crypto";

const hook = fileURLToPath(new URL("./.agents/hooks/write-gate.mjs", import.meta.url));
const phrase = "for the love of everything, please edit, please help me";

const native = process.env.RUN_CODEX_HOOK_TESTS === "1";
test(`${native ? "Actual Codex CLI" : "Codex pre-tool payload"} opens real Zenity and checks typed input`, {
  skip: process.env.RUN_ZENITY_TESTS !== "1" && !native, timeout: 60000,
}, async (t) => {
  for (const command of ["zenity", "Xvfb", "xdotool"]) {
    const found = spawnSync("sh", ["-c", 'command -v "$1"', "sh", command]);
    assert.equal(found.status, 0, `${command} is required for RUN_ZENITY_TESTS=1`);
  }
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "gate-real-gui-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  // Authenticate the isolated TCP display; named X sockets can be read-only
  // in containers. A wildcard Xauthority record works with displayfd selection.
  const auth = path.join(root, "Xauthority");
  const field = (bytes) => {
    const size = Buffer.alloc(2); size.writeUInt16BE(bytes.length);
    return Buffer.concat([size, bytes]);
  };
  fs.writeFileSync(auth, Buffer.concat([Buffer.from([255, 255]), field(Buffer.alloc(0)), field(Buffer.alloc(0)),
    field(Buffer.from("MIT-MAGIC-COOKIE-1")), field(randomBytes(16))]), { mode: 0o600 });
  const display = spawn("Xvfb", ["-displayfd", "3", "-screen", "0", "1024x768x24", "-nolisten", "unix", "-listen", "tcp", "-auth", auth], {
    stdio: ["ignore", "ignore", "pipe", "pipe"],
  });
  let displayErrors = "";
  display.stderr.on("data", (data) => { displayErrors = (displayErrors + data).slice(-2000); });
  t.after(() => display.kill());
  const number = await Promise.race([
    once(display.stdio[3], "data").then(([data]) => data.toString().trim()),
    once(display, "exit").then(() => { throw new Error("Xvfb failed to start: " + displayErrors); }),
  ]);
  const repo = path.join(root, "repo");
  fs.mkdirSync(path.join(repo, ".git"), { recursive: true });
  const state = path.join(root, "state");
  fs.mkdirSync(state);
  fs.writeFileSync(path.join(state, "mode"), "deny");
  const env = { ...process.env, DISPLAY: `localhost:${number}`, XAUTHORITY: auth, WAYLAND_DISPLAY: "", GDK_BACKEND: "x11",
    WRITE_GATE_HOME: state, NVIM: "", NVIM_WORKFLOW_FILE: "" };
  const xdo = async (args) => {
    const child = spawn("xdotool", args, { env });
    const timeout = setTimeout(() => child.kill(), 10000);
    let output = "", errors = "";
    child.stdout.on("data", (data) => { output += data; });
    child.stderr.on("data", (data) => { errors += data; });
    const [code] = await once(child, "exit");
    clearTimeout(timeout);
    assert.equal(code, 0, errors || `xdotool ${args.join(" ")} failed`);
    return output.trim();
  };
  let requests = 0;
  const server = createServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    if (req.method !== "POST") { res.writeHead(200); res.end('{"data":[]}'); return; }
    const body = JSON.parse(Buffer.concat(chunks));
    const tools = body.tools ?? [];
    const tool = tools.find((item) => item.name === "exec_command")
      ?? tools.find((item) => item.name === "shell_command");
    const isFirst = requests++ === 0;
    if (isFirst && !tool) {
      res.writeHead(400); res.end(JSON.stringify({ error: { message: "No shell tool in Codex request" } })); return;
    }
    const item = isFirst ? { type: "function_call", id: "fc_test", call_id: "call_test", name: tool.name,
      arguments: JSON.stringify({ [tool.name === "exec_command" ? "cmd" : "command"]: "touch native-smoke.txt" }) }
      : { type: "message", id: "msg_test", role: "assistant", content: [{ type: "output_text", text: "Test finished." }] };
    res.writeHead(200, { "Content-Type": "text/event-stream" });
    for (const event of [
      { type: "response.created", response: { id: "resp_test", status: "in_progress", output: [] } },
      { type: "response.output_item.added", output_index: 0, item },
      { type: "response.output_item.done", output_index: 0, item },
      { type: "response.completed", response: { id: "resp_test", status: "completed", output: [item],
        usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 } } },
    ]) res.write(`data: ${JSON.stringify(event)}\n\n`);
    res.end();
  });
  let address;
  if (native) {
    const home = path.join(root, "home"); fs.mkdirSync(home);
    env.HOME = home;
    env.CODEX_HOME = path.join(home, ".codex");
    env.CLAUDE_CONFIG_DIR = path.join(home, ".claude");
    const installed = spawnSync(process.execPath, [fileURLToPath(new URL("./install.mjs", import.meta.url)), "--agents-only"], { env, encoding: "utf8" });
    assert.equal(installed.status, 0, installed.stderr);
    server.listen(0, "127.0.0.1"); await once(server, "listening");
    address = `http://127.0.0.1:${server.address().port}/v1`;
    t.after(() => server.close());
  }
  for (const answer of ["wrong phrase", phrase]) {
    requests = 0;
    const child = native ? spawn("codex", ["exec", "--ephemeral", "--skip-git-repo-check", "--dangerously-bypass-hook-trust",
      "-C", repo, "-s", "workspace-write", "-m", "gpt-5.4", "-c", 'model_provider="gate_test"',
      "-c", `model_providers.gate_test={name="Local gate test",base_url="${address}",wire_api="responses",requires_openai_auth=false}`,
      "Create native-smoke.txt using the shell. If denied, stop. This is an isolated integration test."],
      { env, stdio: ["pipe", "pipe", "pipe"] })
      : spawn(process.execPath, [hook, "tool", "--agent=codex"], { env, stdio: ["pipe", "pipe", "pipe"] });
    t.after(() => child.kill());
    let output = "", errors = "";
    child.stdout.on("data", (data) => { output += data; });
    child.stderr.on("data", (data) => { errors += data; });
    const exited = once(child, "exit");
    await new Promise((resolve) => child.stdin.end(native ? "" : JSON.stringify({ session_id: "real-gui-test", cwd: repo, tool_name: "apply_patch",
      tool_input: { command: "*** Begin Patch\n*** Add File: test.txt\n+hello\n*** End Patch" } }), resolve));
    console.log("Waiting for real dialog:", answer === phrase ? "approve" : "reject");
    const window = (await xdo(["search", "--sync", "--onlyvisible", "--name", "^Write gate$"])).split("\n")[0];
    assert.ok(window, "Zenity window never appeared");
    console.log("Real dialog found", window);
    // A bare Xvfb has no window manager, so focus directly rather than activate.
    await xdo(["windowfocus", "--sync", window]);
    await xdo(["type", "--clearmodifiers", "--delay", "1", answer]);
    await xdo(["key", "--clearmodifiers", "Return"]);
    const [code] = await exited;
    assert.equal(code, 0, errors);
    if (native) {
      assert.equal(fs.existsSync(path.join(repo, "native-smoke.txt")), answer === phrase, errors + output);
    } else if (answer === phrase) assert.equal(output.trim(), "");
    else assert.equal(JSON.parse(output).hookSpecificOutput.permissionDecision, "deny");
  }
});
