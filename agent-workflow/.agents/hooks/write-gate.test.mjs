import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { toolArgs, writeTargets, describeCall, viewItems, approvalText } from "./write-gate.mjs";

const hook = fileURLToPath(new URL("./write-gate.mjs", import.meta.url));

function fixture(t) {
	const root = fs.mkdtempSync(path.join(os.tmpdir(), "write-gate-test-"));
	t.after(() => fs.rmSync(root, { recursive: true, force: true }));
	const repo = path.join(root, "repo");
	fs.mkdirSync(path.join(repo, ".git"), { recursive: true });
	return { root, repo };
}

test("raw apply_patch is an edit with exact paths, not a shell command", (t) => {
	const { repo } = fixture(t);
	const patch = "*** Begin Patch\n*** Add File: new file.txt\n+sudo rm unrelated\n+git commit\n*** End Patch";
	const args = toolArgs({ toolArgs: patch });
	assert.deepEqual(writeTargets("apply_patch", args, repo), [repo]);
	const items = viewItems("apply_patch", args, repo);
	assert.equal(items.length, 1);
	assert.equal(items[0].path, path.join(repo, "new file.txt"));
	assert.equal(items[0].added, 2);
	assert.equal(items[0].isNew, true);
	assert.match(describeCall("apply_patch", args, repo).join("\n"), /^EDIT create:/);
});

test("moves authorize both repositories and preserve every edited path", (t) => {
	const { root, repo } = fixture(t);
	const other = path.join(root, "other");
	fs.mkdirSync(path.join(other, ".git"), { recursive: true });
	fs.writeFileSync(path.join(repo, "old.txt"), "first\nold\nlast\n");
	fs.writeFileSync(path.join(repo, "deleted.txt"), "one\ntwo\n");
	const patch = [
		"*** Begin Patch", "*** Update File: old.txt", `*** Move to: ${other}/moved.txt`,
		"@@", "-old", "+new", "*** Delete File: deleted.txt", "*** End Patch",
	].join("\n");
	const args = { patch };
	assert.deepEqual(new Set(writeTargets("functions.apply_patch", args, repo)), new Set([repo, other]));
	const items = viewItems("apply_patch", args, repo);
	assert.equal(items[0].oldPath, path.join(repo, "old.txt"));
	assert.equal(items[0].path, path.join(other, "moved.txt"));
	assert.equal(items[0].line, 2);
	assert.equal(items[1].operation, "delete");
	assert.equal(items[1].removed, 2);
});

test("large edits and multiline commands produce bounded, distinct dialog summaries", (t) => {
	const { repo } = fixture(t);
	const body = Array.from({ length: 200 }, (_, i) => `+payload_line_${i}`);
	const args = { command: ["*** Begin Patch", "*** Add File: big.txt", ...body, "*** End Patch"].join("\n") };
	const views = viewItems("apply_patch", args, repo);
	const preview = describeCall("apply_patch", args, repo);
	const text = approvalText([{ targets: [repo], views, preview }]);
	assert.match(text, /EDIT create: big.txt/);
	assert.match(text, /\+200/);
	assert.doesNotMatch(text, /payload_line/);
	assert.ok(text.length < 1000);
	const command = { command: Array(200).fill("printf 'hello'").join("\n") };
	const execute = describeCall("bash", command, repo);
	assert.match(execute[0], /^EXECUTE:/);
	assert.equal(execute.length, 2);
	assert.match(execute[1], /200 command lines/);
	assert.deepEqual(viewItems("bash", args, repo), []);
	const many = approvalText(Array.from({ length: 50 }, () => ({ targets: [repo], preview })));
	assert.ok(many.split("\n").length < 25);
	assert.match(many, /more preview line/);
});

test("native edit tools keep their file previews and correct post-edit location", (t) => {
	const { repo } = fixture(t);
	const file = path.join(repo, "edit.txt");
	const args = { path: file, old_str: "old", new_str: "new" };
	fs.writeFileSync(file, "first\nold\nlast\n");
	assert.deepEqual(writeTargets("edit", args, repo), [repo]);
	assert.equal(viewItems("edit", args, repo)[0].line, 2);
	fs.writeFileSync(file, "first\nnew\nlast\n");
	assert.equal(viewItems("edit", args, repo, true)[0].line, 2);
	assert.match(describeCall("edit", args, repo)[0], /^EDIT update:/);
});

test("post-edit RPC opens the last existing file beside chat without stealing focus", async (t) => {
	const { root, repo } = fixture(t);
	const socket = path.join(root, "nvim.sock");
	const file = path.join(repo, "changed.txt");
	fs.writeFileSync(file, "new\n");
	const config = path.join(os.homedir(), ".config", "nvim");
	const server = spawn("nvim", [
		"--headless", "-u", "NONE", "-i", "NONE", "--listen", socket,
		"--cmd", `lua vim.opt.rtp:append(${JSON.stringify(config)})`,
		"--cmd", "lua vim.bo.filetype='codecompanion'",
	], { stdio: ["pipe", "ignore", "pipe"] });
	let errors = "";
	server.stderr.on("data", (chunk) => { errors += chunk; });
	const remote = (expression) => {
		const result = spawnSync("nvim", ["--server", socket, "--remote-expr", expression], { encoding: "utf8", timeout: 5000 });
		assert.equal(result.status, 0, result.stderr || errors);
		return result.stdout.trim();
	};
	try {
		for (let i = 0; i < 100 && !fs.existsSync(socket); i++) {
			assert.equal(server.exitCode, null, errors);
			await new Promise((resolve) => setTimeout(resolve, 20));
		}
		assert.ok(fs.existsSync(socket), errors);
		const patch = "*** Begin Patch\n*** Add File: changed.txt\n+new\n*** Delete File: gone.txt\n*** End Patch";
		const result = spawnSync(process.execPath, [hook, "done"], {
			env: { ...process.env, NVIM: socket, WRITE_GATE_HOME: path.join(root, "gate") },
			input: JSON.stringify({ toolName: "apply_patch", toolArgs: patch, cwd: repo }),
			encoding: "utf8", timeout: 10000,
		});
		assert.equal(result.status, 0, result.stderr);
		assert.equal(remote(`luaeval("vim.fn.bufwinid(_A)", ${JSON.stringify(file)})`) === "-1", false);
		assert.equal(remote('luaeval("vim.bo.filetype")'), "codecompanion");
		assert.equal(remote('luaeval("#vim.api.nvim_list_wins()")'), "2");
	} finally {
		if (server.exitCode === null) {
			const exited = new Promise((resolve) => server.once("exit", resolve));
			server.kill("SIGTERM");
			await exited;
		}
	}
});

function planGate(t, status = "running", approved = true) {
	const { root, repo } = fixture(t);
	const other = path.join(root, "other");
	fs.mkdirSync(path.join(other, ".git"), { recursive: true });
	const home = path.join(root, "gate");
	fs.mkdirSync(home);
	fs.writeFileSync(path.join(home, "mode"), "deny");
	const stateDir = path.join(root, "xdg", "nvim", "copilot-workflows");
	fs.mkdirSync(stateDir, { recursive: true });
	const file = path.join(stateDir, "wf.json");
	fs.writeFileSync(file, JSON.stringify({
		cwd: repo, active: 0,
		units: [{ status, attempt: 1, approved_attempt: approved ? 1 : 0, plan_commands: ["git commit -m done"] }],
	}));
	const run = (toolName, args, env = {}) => {
		const result = spawnSync("node", [hook, "tool"], {
			input: JSON.stringify({ toolName, toolArgs: args, cwd: repo }),
			encoding: "utf8",
			env: {
				...process.env, DISPLAY: "", WAYLAND_DISPLAY: "", WRITE_GATE_HOME: home,
				XDG_STATE_HOME: path.join(root, "xdg"), NVIM_WORKFLOW_FILE: file, ...env,
			},
		});
		return result.stdout.includes('"deny"') ? "deny" : "allow";
	};
	return { repo, other, home, file, run };
}

test("an approved plan lets the agent work in its repo, but listed commands only", (t) => {
	const { repo, other, run } = planGate(t);
	assert.equal(run("edit", { path: path.join(repo, "a.txt") }), "allow");
	assert.equal(run("bash", { command: "touch b.txt && git add -A" }), "allow");
	assert.equal(run("edit", { path: path.join(other, "a.txt") }), "deny", "Other repos still ask");
	assert.equal(run("bash", { command: `touch ${other}/x` }), "deny");
	assert.equal(run("bash", { command: "git commit -m other" }), "deny", "Unlisted commit asks");
	assert.equal(run("bash", { command: "git commit -m done" }), "allow", "The listed commit is pre-approved");
	for (const command of ["git push", "git reset --hard", "git checkout .", "git clean -fd", "rm -rf build", "sudo ls"]) {
		assert.equal(run("bash", { command }), "deny", command);
	}
});

test("without a running approved plan the gate behaves as before", (t) => {
	for (const [status, approved] of [["planning", false], ["awaiting_plan", false], ["awaiting_review", true], ["running", false]]) {
		const { repo, run } = planGate(t, status, approved);
		assert.equal(run("edit", { path: path.join(repo, "a.txt") }), "deny", `${status}/${approved}`);
	}
	const { repo, run } = planGate(t);
	assert.equal(run("edit", { path: path.join(repo, "a.txt") }, { NVIM_WORKFLOW_FILE: "" }), "deny");
});

test("agents cannot write the gate or workflow state, so they cannot approve their own plan", (t) => {
	const { home, file, run } = planGate(t, "planning", false);
	assert.equal(run("bash", { command: `echo '{}' > ${file}` }), "deny");
	assert.equal(run("bash", { command: `sed -i s/planning/running/ ${file}` }), "deny");
	assert.equal(run("edit", { path: file }), "deny");
	assert.equal(run("bash", { command: `touch ${path.join(home, "approved.json")}` }), "deny");
	assert.equal(run("bash", { command: `cat ${file}` }), "allow", "Reading is fine");
});
