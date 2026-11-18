#!/usr/bin/env node
/**
 * Shared write gate for Copilot, Codex, Claude Code, and hook-capable clients.
 *
 * Rule: an agent may not change content inside any git repository unless the
 * user's own latest message contains the approval phrase. The local Wayfinder
 * tracker under ~/wayfinder is exempt. Paths outside every git repo (for
 * example /tmp) are free.
 *
 * Modes (argv[2]):
 *   prompt - reads the user's message. Writes the approval marker when the
 *            phrase is present and removes it otherwise, so approval never
 *            outlives the turn and an agent cannot grant it to itself.
 *   tool   - reads a pending tool call and denies repo writes without approval.
 *            In deny mode a blocked call first opens a zenity entry box; the
 *            call is allowed only if the typed text equals the phrase. If
 *            zenity or a display is missing, it falls back to the chat marker.
 *            Escalated calls (sudo/su/doas, git commit outside ALLOWLIST)
 *            ignore the chat marker whenever a dialog can be shown.
 *
 * State lives outside every repo in $XDG_STATE_HOME/agent-workflow/write-gate
 * (existing ~/.copilot/write-gate installations are reused; override with
 * WRITE_GATE_HOME):
 *   mode          "log" (default) or "deny". In log mode nothing is blocked;
 *                 would-be denials are only recorded.
 *   approved.json the approval marker.
 *   events.jsonl  one line per hook call, with the raw payload.
 *
 * The gate only subtracts permission: it prints a deny decision or nothing.
 * It fails open on internal errors so a bug here cannot lock the session.
 *
 * Plan grant: when $NVIM_WORKFLOW_FILE points at a workflow whose active unit
 * is "running" and whose plan the user approved in nvim, writes inside that
 * workflow's repo are allowed without a dialog. Privileged commands, git
 * commit/push/reset/clean/checkout/restore/stash/rebase/merge/etc and recursive
 * rm still ask unless the approved plan listed that exact command. The grant
 * ends when the unit leaves "running". Agents may not write to this gate's
 * state dir or the workflow state dir, so they cannot approve their own plan.
 *
 * Not covered: writes smuggled through an interpreter (python -c, node -e),
 * encoded payloads, or a script that writes as a side effect.
 */

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { createHash, randomUUID } from "node:crypto";
import { pathToFileURL } from "node:url";

const PHRASE = "for the love of everything, please edit, please help me";

const STATE_DIR =
	process.env.WRITE_GATE_HOME ??
	(fs.existsSync(path.join(os.homedir(), ".copilot", "write-gate"))
		? path.join(os.homedir(), ".copilot", "write-gate")
		: path.join(process.env.XDG_STATE_HOME ?? path.join(os.homedir(), ".local", "state"), "agent-workflow", "write-gate"));
const MODE_FILE = path.join(STATE_DIR, "mode");
const EVENT_LOG = path.join(STATE_DIR, "events.jsonl");
const WAYFINDER_ROOT = path.join(os.homedir(), "wayfinder");
// Repos and folders the gate never blocks.
const ALLOWLIST = [WAYFINDER_ROOT];
const WORKFLOW_STATE_DIR = path.join(
	process.env.XDG_STATE_HOME ?? path.join(os.homedir(), ".local", "state"),
	"nvim",
	"copilot-workflows",
);
// Agents may never write here: it holds the approvals a plan grant is read from.
const PROTECTED = [STATE_DIR, WORKFLOW_STATE_DIR,
	path.join(process.env.XDG_STATE_HOME ?? path.join(os.homedir(), ".local", "state"), "nvim", "agent-workflows")];
const PRIVILEGE_COMMANDS = new Set(["sudo", "su", "doas", "pkexec"]);

const SHELL_TOOL = /^(bash|sh|shell|powershell|terminal|run_?in_?terminal|exec|execute)/i;
const EDIT_TOOL = /edit|write|create|delete|remove|patch|apply|move|rename/i;
const PATH_KEY = /(path|file|filename)s?$/i;

const WRITE_COMMANDS = new Set([
	"cp",
	"mv",
	"rm",
	"rmdir",
	"mkdir",
	"touch",
	"truncate",
	"ln",
	"chmod",
	"chown",
	"unlink",
	"tee",
	"dd",
	"install",
	"patch",
	"set-content",
	"add-content",
	"out-file",
	"new-item",
	"remove-item",
	"move-item",
	"copy-item",
	"clear-content",
	"rename-item",
]);
const IN_PLACE_COMMANDS = new Set(["sed", "perl", "ruby"]);
const GIT_WRITE = new Set([
	"add",
	"commit",
	"apply",
	"am",
	"mv",
	"rm",
	"cherry-pick",
	"revert",
	"merge",
	"rebase",
	"push",
	"checkout",
	"switch",
	"restore",
	"reset",
	"clean",
	"stash",
	"pull",
	"tag",
]);
const NULL_SINKS = new Set(["/dev/null", "/dev/stdout", "/dev/stderr", "$null"]);
const SEGMENT_OPERATORS = new Set(["|", "||", "&&", ";", "&"]);

function normalise(text) {
	return String(text ?? "")
		.toLowerCase()
		.replace(/\s+/g, " ")
		.trim();
}

function readMode() {
	try {
		return fs.readFileSync(MODE_FILE, "utf8").trim() === "deny"
			? "deny"
			: "log";
	} catch {
		return "log";
	}
}

function readPayload() {
	try {
		const raw = fs.readFileSync(0, "utf8").trim();
		return raw ? JSON.parse(raw) : {};
	} catch {
		return {};
	}
}

function record(entry) {
	try {
		fs.mkdirSync(STATE_DIR, { recursive: true });
		fs.appendFileSync(
			EVENT_LOG,
			`${JSON.stringify({ at: new Date().toISOString(), ...entry })}\n`,
		);
	} catch {
		// Logging must never break a session.
	}
}

function allStrings(value, out = []) {
	if (typeof value === "string") out.push(value);
	else if (Array.isArray(value)) for (const v of value) allStrings(v, out);
	else if (value && typeof value === "object") {
		for (const v of Object.values(value)) allStrings(v, out);
	}
	return out;
}

function promptText(payload) {
	for (const key of ["prompt", "userPrompt", "user_prompt", "message", "text"]) {
		if (typeof payload[key] === "string") return payload[key];
	}
	return allStrings(payload).join("\n");
}

// Native hook registrations pass --agent=...; legacy Copilot calls need no flag.
const AGENT = process.argv.find((arg) => arg.startsWith("--agent="))?.slice(8) ?? "copilot";
function markerFor(payload) {
	const session = payload.session_id ?? payload.sessionId;
	if (!session) return path.join(STATE_DIR, `${AGENT === "copilot" ? "approved" : `${AGENT}-approved`}.json`);
	const scope = createHash("sha256").update(`${AGENT}:${session}`).digest("hex");
	return path.join(STATE_DIR, `approved-${scope}.json`);
}

// Preserve old payloads while accepting native hooks and ACP tool-call records.
function normalisePayload(payload) {
	const call = payload.toolCall ?? {};
	const args = toolArgs({ ...payload, toolArgs: payload.toolArgs ?? payload.tool_input
		?? payload.toolInput ?? payload.arguments ?? payload.args ?? call.rawInput ?? {} });
	if (typeof args.cmd === "string" && args.command === undefined) args.command = args.cmd;
	return { ...payload, toolName: payload.toolName ?? payload.tool_name ?? payload.name ?? call.name ?? call.kind ?? "",
		toolArgs: args, cwd: payload.tool_cwd ?? payload.cwd ?? process.cwd(),
		toolCallId: payload.toolCallId ?? payload.tool_use_id ?? payload.tool_call_id ?? call.toolCallId };
}

function formatDecision(decision, agent = AGENT) {
	if (!decision) return null; // Abstain; do not bypass the agent's own approvals.
	return ["codex", "claude"].includes(agent)
		? { hookSpecificOutput: { hookEventName: "PreToolUse", ...decision } }
		: decision;
}

function runPrompt(payload) {
	const MARKER = markerFor(payload);
	const text = promptText(payload);
	// Runtime notifications are not user messages: they must neither grant
	// approval nor cancel an approval given earlier in the same turn.
	if (text.trimStart().startsWith("<system_notification>")) {
		record({ event: "prompt", ignored: "system_notification" });
		return;
	}
	const approved = normalise(text).includes(PHRASE);
	try {
		fs.mkdirSync(STATE_DIR, { recursive: true });
		if (approved) {
			fs.writeFileSync(
				MARKER,
				`${JSON.stringify({ at: new Date().toISOString() })}\n`,
			);
		} else {
			fs.rmSync(MARKER, { force: true });
		}
	} catch (error) {
		process.stderr.write(`write-gate: marker update failed: ${error}\n`);
	}
	record({ event: "prompt", approved, payload: payload });
}

/** Resolves a path through symlinks even when the leaf does not exist yet. */
function realish(absolute) {
	let existing = absolute;
	const rest = [];
	while (!fs.existsSync(existing)) {
		const parent = path.dirname(existing);
		if (parent === existing) break;
		rest.unshift(path.basename(existing));
		existing = parent;
	}
	let base = existing;
	try {
		base = fs.realpathSync(existing);
	} catch {
		// Keep the unresolved path.
	}
	return path.join(base, ...rest);
}

/** The git work tree root containing the path, or null. */
function repoOf(candidate, cwd) {
	const text = String(candidate ?? "").trim();
	if (!text || NULL_SINKS.has(text)) return null;
	const expanded = text.startsWith("~")
		? path.join(os.homedir(), text.slice(1))
		: text;
	const absolute = path.resolve(cwd, expanded);
	let dir = realish(absolute);
	for (;;) {
		if (fs.existsSync(path.join(dir, ".git"))) return dir;
		const parent = path.dirname(dir);
		if (parent === dir) return null;
		dir = parent;
	}
}

function tokenize(command) {
	const tokens = [];
	let current = "";
	let started = false;
	let quote = null;
	const flush = () => {
		if (started) tokens.push({ value: current });
		current = "";
		started = false;
	};
	for (let i = 0; i < command.length; i += 1) {
		const char = command[i];
		if (quote) {
			if (char === quote) quote = null;
			else current += char;
			started = true;
			continue;
		}
		if (char === '"' || char === "'") {
			quote = char;
			started = true;
			continue;
		}
		if (/\s/.test(char)) {
			flush();
			continue;
		}
		if ("|&;<>".includes(char)) {
			flush();
			let operator = char;
			while ("<>|&".includes(char) && command[i + 1] === char) {
				operator += char;
				i += 1;
			}
			tokens.push({ value: operator, operator: true });
			continue;
		}
		current += char;
		started = true;
	}
	flush();
	return tokens;
}

function splitSegments(tokens) {
	const segments = [];
	let words = [];
	let redirects = [];
	let expectRedirect = false;
	const flush = () => {
		if (words.length || redirects.length) segments.push({ words, redirects });
		words = [];
		redirects = [];
	};
	for (const token of tokens) {
		if (token.operator) {
			if (SEGMENT_OPERATORS.has(token.value)) {
				flush();
				expectRedirect = false;
			} else {
				expectRedirect = token.value.startsWith(">");
			}
			continue;
		}
		if (expectRedirect) {
			redirects.push(token.value);
			expectRedirect = false;
			continue;
		}
		words.push(token.value);
	}
	flush();
	return segments;
}

const isAssignment = (word) => /^[A-Za-z_][A-Za-z0-9_]*=/.test(word);

/** Repo roots a shell command would change. */
function shellTargets(command, startCwd, resolve = repoOf) {
	const targets = new Set();
	let cwd = startCwd;
	for (const segment of splitSegments(tokenize(command))) {
		for (const redirect of segment.redirects) {
			const repo = resolve(redirect, cwd);
			if (repo) targets.add(repo);
		}
		const index = segment.words.findIndex((w) => !isAssignment(w));
		if (index === -1) continue;
		const word = path.basename(segment.words[index]).toLowerCase();
		const args = segment.words.slice(index + 1);

		if (word === "cd") {
			if (args[0]) cwd = path.resolve(cwd, args[0].replace(/^~/, os.homedir()));
			continue;
		}
		if (word === "git") {
			let gitCwd = cwd;
			let rest = args;
			while (rest[0] === "-C" && rest[1]) {
				gitCwd = path.resolve(gitCwd, rest[1]);
				rest = rest.slice(2);
			}
			const sub = rest.find((a) => !a.startsWith("-"));
			if (resolve === repoOf && sub && GIT_WRITE.has(sub)) {
				const repo = repoOf(gitCwd, gitCwd);
				if (repo) targets.add(repo);
			}
			continue;
		}
		const inPlace =
			IN_PLACE_COMMANDS.has(word) && args.some((a) => /^-{1,2}i/.test(a));
		if (WRITE_COMMANDS.has(word) || inPlace) {
			let skipped = !inPlace;
			for (const arg of args) {
				if (arg.startsWith("-")) continue;
				if (!skipped) {
					skipped = true;
					continue;
				}
				const repo = resolve(arg.startsWith("of=") ? arg.slice(3) : arg, cwd);
				if (repo) targets.add(repo);
			}
		}
	}
	return [...targets];
}

function isAllowlisted(repo) {
	return ALLOWLIST.map(realish).some(
		(root) => repo === root || repo.startsWith(`${root}${path.sep}`),
	);
}

/** Reasons a shell command is escalated: privilege use or a git commit. */
function shellEscalations(command, startCwd) {
	const reasons = new Set();
	let cwd = startCwd;
	for (const segment of splitSegments(tokenize(command))) {
		const index = segment.words.findIndex((w) => !isAssignment(w));
		if (index === -1) continue;
		const word = path.basename(segment.words[index]).toLowerCase();
		const args = segment.words.slice(index + 1);
		if (PRIVILEGE_COMMANDS.has(word)) reasons.add(`${word} (privileged command)`);
		if (word === "cd" && args[0]) {
			cwd = path.resolve(cwd, args[0].replace(/^~/, os.homedir()));
		}
		if (word === "git") {
			let gitCwd = cwd;
			let rest = args;
			while (rest[0] === "-C" && rest[1]) {
				gitCwd = path.resolve(gitCwd, rest[1]);
				rest = rest.slice(2);
			}
			if (rest.find((a) => !a.startsWith("-")) === "commit") {
				const repo = repoOf(gitCwd, gitCwd);
				if (repo && !isAllowlisted(repo)) reasons.add(`git commit in ${repo}`);
			}
		}
	}
	return [...reasons];
}

function toolArgs(payload) {
	let args = payload.toolArgs ?? payload.tool_input ?? payload.toolInput ?? payload.arguments ?? {};
	if (typeof args === "string") {
		try {
			args = JSON.parse(args);
		} catch {
			args = { command: args };
		}
	}
	return args && typeof args === "object" ? args : {};
}

function collectPaths(value, keyMatched, out) {
	if (typeof value === "string") {
		if (keyMatched) out.push(value);
	} else if (Array.isArray(value)) {
		for (const v of value) collectPaths(v, keyMatched, out);
	} else if (value && typeof value === "object") {
		for (const [key, nested] of Object.entries(value)) {
			collectPaths(nested, keyMatched || PATH_KEY.test(key), out);
		}
	}
}

function writeTargets(toolName, args, cwd, resolve = repoOf) {
	const patch = patchText(toolName, args);
	if (patch !== null) {
		const repos = new Set();
		for (const item of patchItems(patch, cwd)) {
			for (const file of [item.path, item.oldPath]) {
				const repo = file && resolve(file, cwd);
				if (repo) repos.add(repo);
			}
		}
		return [...repos];
	}
	const command = typeof args.command === "string" ? args.command : null;
	if (command !== null || SHELL_TOOL.test(toolName)) {
		return command ? shellTargets(command, cwd, resolve) : [];
	}
	if (!EDIT_TOOL.test(toolName)) return [];
	const paths = [];
	collectPaths(args, false, paths);
	const repos = new Set();
	for (const candidate of paths) {
		const repo = resolve(candidate, cwd);
		if (repo) repos.add(repo);
	}
	return [...repos];
}

/** The protected state dir containing the path, or null. Same shape as repoOf so writeTargets can use it. */
function protectedOf(candidate, cwd) {
	const text = String(candidate ?? "").trim();
	if (!text || NULL_SINKS.has(text)) return null;
	const expanded = text.startsWith("~") ? path.join(os.homedir(), text.slice(1)) : text;
	const absolute = realish(path.resolve(cwd, expanded));
	return (
		PROTECTED.map(realish).find((dir) => absolute === dir || absolute.startsWith(`${dir}${path.sep}`)) ?? null
	);
}

/** The approved-plan grant of the workflow this agent runs in, or null. */
function planGrant() {
	const file = process.env.NVIM_WORKFLOW_FILE;
	if (!file) return null;
	const state = readJson(file);
	const unit = state?.units?.[state.active];
	if (!unit || unit.status !== "running" || unit.approved_attempt !== unit.attempt) return null;
	const repo = typeof state.cwd === "string" ? repoOf(state.cwd, state.cwd) : null;
	if (!repo) return null;
	return { repo, commands: (unit.plan_commands ?? []).map(normalise) };
}

const HARD_GIT = new Set([...GIT_WRITE].filter((sub) => !["add", "apply", "mv", "rm"].includes(sub)));

/** Privileged, history-rewriting or recursive-delete commands: these must be listed in the approved plan. */
function needsListing(command) {
	for (const segment of splitSegments(tokenize(command))) {
		const index = segment.words.findIndex((w) => !isAssignment(w));
		if (index === -1) continue;
		const word = path.basename(segment.words[index]).toLowerCase();
		const args = segment.words.slice(index + 1);
		if (PRIVILEGE_COMMANDS.has(word)) return true;
		if (word === "rm" && args.some((a) => /^-[a-z]*[rRf]/.test(a) || a === "--recursive" || a === "--force")) return true;
		if (word === "git") {
			let rest = args;
			while (rest[0] === "-C" && rest[1]) rest = rest.slice(2);
			if (HARD_GIT.has(rest.find((a) => !a.startsWith("-")))) return true;
		}
	}
	return false;
}

function coveredByPlan(grant, command, targets, escalations) {
	if (!grant || targets.some((repo) => repo !== grant.repo)) return false;
	if (command !== null && (escalations.length > 0 || needsListing(command))) {
		return grant.commands.includes(normalise(command));
	}
	return escalations.length === 0;
}

const DIALOG_TIMEOUT_SEC = 90;
// Parallel tool calls that arrive within this window share one dialog.
const BATCH_WINDOW_MS = 2000;
const HOOK_BUDGET_MS = 95_000;
const LOCK_STALE_MS = (DIALOG_TIMEOUT_SEC + 20) * 1000;
const PREVIEW_MAX_LINES = 12;
const BATCH_DIR = path.join(STATE_DIR, "batch");
const PENDING_DIR = path.join(BATCH_DIR, "pending");
const DECIDED_DIR = path.join(BATCH_DIR, "decided");
const LOCK_DIR = path.join(BATCH_DIR, "lock");

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const clip = (text, max = 110) => {
	const flat = String(text).replace(/\t/g, "  ");
	return flat.length > max ? `${flat.slice(0, max - 1)}…` : flat;
};

const escapeMarkup = (text) =>
	text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

function displayPath(candidate, cwd) {
	const text = String(candidate);
	const expanded = text.startsWith("~") ? path.join(os.homedir(), text.slice(1)) : text;
	const absolute = path.resolve(cwd, expanded);
	const relative = path.relative(cwd, absolute);
	if (relative && !relative.startsWith("..")) return relative;
	return absolute.startsWith(os.homedir())
		? `~${absolute.slice(os.homedir().length)}`
		: absolute;
}

function sample(lines, marker, limit) {
	const shown = lines.slice(0, limit).map((line) => `   ${marker} ${clip(line)}`);
	if (lines.length > limit) shown.push(`   … ${lines.length - limit} more`);
	return shown;
}

/** Short, readable description of one tool call for the approval dialog. */
function describeCall(toolName, args, cwd) {
	const views = viewItems(toolName, args, cwd);
	if (views.length > 0) {
		return [
			...views.slice(0, 6).map((view) =>
				`EDIT ${view.operation ?? (view.isNew ? "create" : "update")}: ${clip(view.name)}  (+${view.added} -${view.removed} lines)`),
			...(views.length > 6 ? [`… ${views.length - 6} more file(s)`] : []),
		];
	}
	if (typeof args.command === "string") {
		const lines = args.command.split("\n");
		if (/apply_?patch$/i.test(toolName) && lines[0] === "*** Begin Patch") {
			const files = lines.filter((line) => /^\*\*\* (Add|Update|Delete) File: /.test(line));
			return [
				`EDIT: ${files.length} file(s)`,
				...files.slice(0, 6).map((line) => clip(line.slice(4))),
				...(files.length > 6 ? [`… ${files.length - 6} more file(s)`] : []),
			];
		}
		const first = lines.find((line) => line.trim()) ?? "";
		return [`EXECUTE: $ ${clip(first)}`, ...(lines.length > 1 ? [`   (${lines.length} command lines)`] : [])];
	}
	const paths = [];
	collectPaths(args, false, paths);
	const files = [...new Set(paths)].slice(0, 3).map((p) => displayPath(p, cwd));
	const out = [`${toolName}: ${files.join(", ") || "(unknown file)"}`];
	const pick = (...keys) => keys.map((k) => args[k]).find((v) => typeof v === "string");
	const split = (text) => (text === "" ? [] : text.split("\n"));
	const oldText = pick("old_str", "old_string", "oldString");
	const newText = pick("new_str", "new_string", "newString");
	const created = pick("file_text", "content", "contents", "text");
	if (oldText !== undefined || newText !== undefined) {
		const removed = split(oldText ?? "");
		const added = split(newText ?? "");
		out.push(
			`   (-${removed.length} +${added.length} lines)`,
			...sample(removed, "-", 5),
			...sample(added, "+", 5),
		);
	} else if (created !== undefined) {
		const added = split(created);
		out.push(`   (+${added.length} lines)`, ...sample(added, "+", 8));
	}
	return out;
}

function absolutePath(candidate, cwd) {
	const text = String(candidate);
	const expanded = text.startsWith("~") ? path.join(os.homedir(), text.slice(1)) : text;
	return path.resolve(cwd, expanded);
}

function patchText(toolName, args) {
	if (!/(?:^|[.:/_-])apply_?patch$/i.test(toolName)) return null;
	const text = args.patch ?? args.input ?? args.command;
	return typeof text === "string" && text.startsWith("*** Begin Patch") ? text : null;
}

function patchItems(patch, cwd, after = false) {
	const entries = [];
	let entry;
	for (const line of patch.replace(/\r\n/g, "\n").split("\n")) {
		const header = line.match(/^\*\*\* (Add|Update|Delete) File: (.+)$/);
		if (header) {
			entry = { operation: { Add: "create", Update: "update", Delete: "delete" }[header[1]],
				path: absolutePath(header[2], cwd), lines: [] };
			entries.push(entry);
		} else if (line.startsWith("*** Move to: ") && entry) {
			entry.oldPath = entry.path;
			entry.path = absolutePath(line.slice("*** Move to: ".length), cwd);
			entry.operation = "move";
		} else if (entry && !line.startsWith("*** ")) {
			entry.lines.push(line);
		}
	}
	return entries.map((item) => {
		let removed = item.lines.filter((line) => line.startsWith("-")).length;
		const added = item.lines.filter((line) => line.startsWith("+")).length;
		const file = after ? item.path : item.oldPath ?? item.path;
		let content = "";
		try {
			content = fs.readFileSync(file, "utf8");
		} catch (error) {
			if (error.code !== "ENOENT") throw error;
		}
		if (item.operation === "delete" && content) {
			removed = content.split("\n").length - Number(content.endsWith("\n"));
		}
		const first = item.lines.findIndex((line) => line.startsWith("@@"));
		const next = item.lines.findIndex((line, index) => index > first && line.startsWith("@@"));
		const hunk = item.lines.slice(first + 1, next < 0 ? undefined : next);
		const needle = hunk.filter((line) => line.startsWith(" ") || line.startsWith(after ? "+" : "-"))
			.map((line) => line.slice(1)).join("\n");
		const index = needle ? content.indexOf(needle) : -1;
		return {
			path: item.path, oldPath: item.oldPath, operation: item.operation,
			name: displayPath(item.path, cwd), isNew: item.operation === "create",
			added, removed, line: index > 0 ? content.slice(0, index).split("\n").length : 1,
			diff: [`--- ${displayPath(item.oldPath ?? item.path, cwd)}`,
				`+++ ${displayPath(item.path, cwd)}`, ...item.lines].slice(0, 400),
		};
	});
}

function viewItems(toolName, args, cwd, after = false) {
	const patch = patchText(toolName, args);
	if (patch !== null) return patchItems(patch, cwd, after);
	const item = viewItem(toolName, args, cwd, after);
	return item ? [item] : [];
}

/** What an edit-style tool call would change, for the editor view. Null for anything else. */
function viewItem(toolName, args, cwd, after = false) {
	if (typeof args.command === "string" || !EDIT_TOOL.test(toolName)) return null;
	const paths = [];
	collectPaths(args, false, paths);
	if (paths.length === 0) return null;
	const file = absolutePath(paths[0], cwd);
	const pick = (...keys) => keys.map((k) => args[k]).find((v) => typeof v === "string");
	const split = (text) => (text === "" ? [] : text.split("\n"));
	const oldText = pick("old_str", "old_string", "oldString");
	const newText = pick("new_str", "new_string", "newString");
	const created = pick("file_text", "content", "contents", "text");
	const removed = split(oldText ?? "");
	const added = split(newText ?? created ?? "");
	let line = 1;
	const needle = after ? newText : oldText;
	if (needle) {
		try {
			const index = fs.readFileSync(file, "utf8").indexOf(needle);
			if (index > 0) line = fs.readFileSync(file, "utf8").slice(0, index).split("\n").length;
		} catch {
			// New or unreadable file: jump to the top.
		}
	}
	const name = displayPath(file, cwd);
	const diff = [
		`--- ${name}`,
		`+++ ${name}`,
		...removed.map((l) => `-${l}`),
		...added.map((l) => `+${l}`),
	].slice(0, 400);
	return {
		path: file,
		name,
		line,
		added: added.length,
		removed: removed.length,
		isNew: created !== undefined && oldText === undefined,
		diff,
	};
}

/** Calls into the nvim that started this agent ($NVIM). Best effort; never throws. */
function nvimCall(method, argument) {
	const server = process.env.NVIM;
	if (!server) return false;
	try {
		const expr = `luaeval("require('qvd808.custom.agent_gate').${method}(_A)", ${JSON.stringify(argument)})`;
		const result = spawnSync("nvim", ["--server", server, "--remote-expr", expr], {
			timeout: 3000,
			stdio: "ignore",
		});
		return !result.error && result.status === 0;
	} catch {
		return false;
	}
}

/**
 * Asks the user to type the phrase in one zenity entry box covering every call
 * in the batch. Returns "approved", "rejected" (dialog shown, wrong or no
 * input), or "unavailable" (no zenity, no display, or the dialog failed) so
 * the caller can fall back to chat.
 */
function approvalText(batch) {
	const escalated = batch.some((entry) => entry.escalated);
	const count = batch.length;
	const heading = escalated
		? "ESCALATED: an agent wants to run"
		: `An agent wants to make ${count} change${count === 1 ? "" : "s"}`;
	// The diff itself is shown in the editor, so the dialog only lists each call with its line counts
	const lines = batch.flatMap((entry) => (entry.summary ?? entry.preview.join("\n")).split("\n"));
	const shown = lines.slice(0, PREVIEW_MAX_LINES).map((line) => clip(line));
	if (lines.length > PREVIEW_MAX_LINES) {
		shown.push(`… ${lines.length - PREVIEW_MAX_LINES} more preview line(s) not shown`);
	}
	const views = batch.flatMap((entry) => entry.views ?? (entry.view ? [entry.view] : []));
	const added = views.reduce((sum, view) => sum + view.added, 0);
	const removed = views.reduce((sum, view) => sum + view.removed, 0);
	const where = [...new Set(batch.flatMap((entry) => entry.targets))].join(", ");
	return (
		`${escapeMarkup(`${heading} (${where}):`)}\n\n${escapeMarkup(shown.join("\n"))}\n\n` +
		(views.length > 0 ? `<b>Total: +${added} lines added, -${removed} lines deleted</b>\n\n` : "") +
		escapeMarkup(`Type the approval phrase to allow ${count === 1 ? "this call" : `these ${count} calls`}:`)
	);
}

function askViaDialog(batch) {
	if (!process.env.DISPLAY && !process.env.WAYLAND_DISPLAY) return "unavailable";
	const text = approvalText(batch);
	const result = spawnSync(
		"zenity",
		[
			"--entry",
			"--title=Write gate",
			"--width=720",
			`--text=${text}`,
			`--timeout=${DIALOG_TIMEOUT_SEC}`,
		],
		{ encoding: "utf8", timeout: (DIALOG_TIMEOUT_SEC + 5) * 1000 },
	);
	if (result.error || result.signal) return "unavailable";
	if (result.status !== 0) return "rejected";
	return result.stdout.trim().toLowerCase() === PHRASE ? "approved" : "rejected";
}

function readJson(file) {
	try {
		return JSON.parse(fs.readFileSync(file, "utf8"));
	} catch {
		return null;
	}
}

function tryLock() {
	try {
		fs.mkdirSync(LOCK_DIR);
		return true;
	} catch (error) {
		if (error.code !== "EEXIST") throw error;
		try {
			if (Date.now() - fs.statSync(LOCK_DIR).mtimeMs > LOCK_STALE_MS) {
				fs.rmSync(LOCK_DIR, { recursive: true, force: true });
			}
		} catch {
			// Another process already cleaned it up.
		}
		return false;
	}
}

/** Pending calls that should share the leader's dialog. Escalated calls never batch. */
function collectBatch(self) {
	if (self.escalated) return [self];
	const now = Date.now();
	const entries = [];
	for (const name of fs.readdirSync(PENDING_DIR)) {
		const entry = readJson(path.join(PENDING_DIR, name));
		if (!entry || entry.escalated || now - entry.at > HOOK_BUDGET_MS) continue;
		if (fs.existsSync(path.join(DECIDED_DIR, name))) continue;
		entries.push(entry);
	}
	if (!entries.some((entry) => entry.id === self.id)) entries.push(self);
	return entries.sort((a, b) => a.at - b.at);
}

/**
 * Queues the call and returns the dialog result for it. The first waiting
 * process becomes the leader: it waits briefly for sibling calls, shows ONE
 * dialog for the whole batch, and records the result for each of them. Later
 * arrivals wait their turn, so only one dialog is ever open.
 */
async function requestApproval(self) {
	if (!process.env.DISPLAY && !process.env.WAYLAND_DISPLAY) return "unavailable";
	fs.mkdirSync(PENDING_DIR, { recursive: true });
	fs.mkdirSync(DECIDED_DIR, { recursive: true });
	const pendingFile = path.join(PENDING_DIR, `${self.id}.json`);
	const decidedFile = path.join(DECIDED_DIR, `${self.id}.json`);
	fs.writeFileSync(pendingFile, JSON.stringify(self));
	const deadline = Date.now() + HOOK_BUDGET_MS;
	try {
		while (Date.now() < deadline) {
			const decided = readJson(decidedFile);
			if (decided) return decided.result;
			if (tryLock()) {
				try {
					const again = readJson(decidedFile);
					if (again) return again.result;
					if (!self.escalated) await sleep(BATCH_WINDOW_MS);
					const batch = collectBatch(self);
					const result = askViaDialog(batch);
					for (const entry of batch) {
						const file = path.join(DECIDED_DIR, `${entry.id}.json`);
						fs.writeFileSync(`${file}.tmp`, JSON.stringify({ result }));
						fs.renameSync(`${file}.tmp`, file);
					}
				} finally {
					fs.rmSync(LOCK_DIR, { recursive: true, force: true });
				}
				continue;
			}
			await sleep(100);
		}
		return "unavailable";
	} finally {
		fs.rmSync(pendingFile, { force: true });
		fs.rmSync(decidedFile, { force: true });
	}
}

async function runTool(payload) {
	payload = normalisePayload(payload);
	const toolName = String(payload.toolName ?? payload.tool_name ?? payload.name ?? "");
	const args = toolArgs(payload);
	const cwd = typeof payload.cwd === "string" ? payload.cwd : process.cwd();
	const mode = readMode();
	const touched = writeTargets(toolName, args, cwd, protectedOf);
	if (touched.length > 0) {
		record({ event: "tool", mode, toolName, targets: touched, decision: mode === "deny" ? "deny" : "log-only", protected: true, payload });
		if (mode === "deny") {
			const reason = "Write gate: agents may not modify the gate's or the workflow controller's state files.";
			return { permissionDecision: "deny", permissionDecisionReason: reason };
		}
		return;
	}
	const approved = fs.existsSync(markerFor(payload));
	const command = patchText(toolName, args) === null && typeof args.command === "string" ? args.command : null;
	const escalations =
		command !== null || SHELL_TOOL.test(toolName) ? shellEscalations(command ?? "", cwd) : [];
	// A chat approval covers edits only; escalated calls need the typed dialog
	// and use the chat marker only when no dialog can be shown.
	const targets = (approved && escalations.length === 0 ? [] : writeTargets(toolName, args, cwd)).filter(
		(repo) => !isAllowlisted(repo),
	);
	const gated = escalations.length > 0 ? [...escalations] : targets;
	const covered = gated.length > 0 && coveredByPlan(planGrant(), command, targets, escalations);
	let wouldDeny = gated.length > 0 && !covered;
	let dialog = null;
	if (wouldDeny && mode === "deny") {
		const id = `${String(payload.toolCallId ?? "call").replace(/[^\w-]/g, "_")}-${randomUUID()}`;
		const views = viewItems(toolName, args, cwd);
		dialog = await requestApproval({
			id,
			at: Date.now(),
			escalated: escalations.length > 0,
			targets: gated,
			preview: describeCall(toolName, args, cwd),
			views,
			summary: describeCall(toolName, args, cwd).join("\n"),
		});
		if (dialog === "approved" || (dialog === "unavailable" && approved)) wouldDeny = false;
	}

	record({
		event: "tool",
		mode,
		approved,
		dialog,
		toolName,
		targets,
		escalations,
		plan: covered,
		decision: wouldDeny ? (mode === "deny" ? "deny" : "log-only") : "allow",
		payload,
	});
	if (wouldDeny && mode === "deny") {
		const reason =
			dialog === "rejected"
				? `Write gate: the user did not approve ${gated.join(", ")} in the dialog. Do not retry without being asked.`
				: `Write gate: this would change or run ${gated.join(", ")} without approval. ` +
					'The user must send, verbatim: "For the love of everything, please edit, please help me". ' +
					"Ask in plain chat, not with ask_user. " +
					"Do not ask the user to disable this hook, and do not route the write through a shell command or an interpreter.";
		return { permissionDecision: "deny", permissionDecisionReason: reason };
	}
}

/** After an edit tool succeeded: tell the nvim that started this agent so it can refresh and open the file. */
function runDone(payload) {
	payload = normalisePayload(payload);
	const toolName = String(payload.toolName ?? payload.tool_name ?? payload.name ?? "");
	const args = toolArgs(payload);
	const cwd = typeof payload.cwd === "string" ? payload.cwd : process.cwd();
	record({ event: "done", toolName, nvim: Boolean(process.env.NVIM), payload });
	const items = viewItems(toolName, args, cwd, true);
	if (items.length === 0) {
		// Deletes and moves happen through the shell: nothing to open, but nvim should refresh
		if (typeof args.command === "string" && shellTargets(args.command, cwd).length > 0) {
			nvimCall("refresh", "");
		}
		return;
	}
	try {
		const id = String(payload.toolCallId ?? `${process.pid}-${Date.now()}`).replace(/[^\w-]/g, "_");
		fs.mkdirSync(BATCH_DIR, { recursive: true });
		const file = path.join(BATCH_DIR, `changed-${id}.json`);
		fs.writeFileSync(file, JSON.stringify({ items }));
		if (!nvimCall("file_changed", file)) fs.rmSync(file, { force: true });
	} catch {
		// Telling nvim is best effort.
	}
}

export { toolArgs, writeTargets, describeCall, viewItems, approvalText, normalisePayload, formatDecision };

if (process.argv[1] && import.meta.url === pathToFileURL(fs.realpathSync(process.argv[1])).href) try {
	const kind = process.argv[2];
	const payload = readPayload();
	if (kind === "prompt") runPrompt(payload);
	else if (kind === "tool") {
		const calls = Array.isArray(payload.toolCalls)
			? payload.toolCalls.map((call) => ({ ...payload, toolCalls: undefined,
				toolName: call.name, toolArgs: call.args, toolCallId: call.id })) : [payload];
		for (const call of calls) {
			const decision = formatDecision(await runTool(call));
			if (decision) { process.stdout.write(`${JSON.stringify(decision)}\n`); break; }
		}
	}
	else if (kind === "done") runDone(payload);
} catch (error) {
	process.stderr.write(`write-gate: ${error}\n`);
}
