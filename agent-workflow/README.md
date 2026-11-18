# Shared agent workflow

The versioned source stays here. `init.sh` links `~/.agent` to this repo's
`agent-workflow/.agents`, then installs agent-specific discovery and hook entries.
There is one write-gate implementation and one set of skills, not a copy for
each provider.

```sh
./init.sh                 # Neovim, tmux, shared skills, and all three hook adapters
./init.sh --agents-only   # Only the shared agent setup
./init.sh --check         # Agent + Neovim dependencies; nonzero if a required tool is missing
./init.sh --check --agents-only # Check agent tools without requiring Neovim/build tools
```

The script works from any working directory. Conflicting files and directories
are backed up with a `.before-agent-workflow-...` suffix. Existing JSON settings
and unrelated hooks are preserved; rerunning doesn't duplicate our entries.
Restart running agents after installation. Codex may require reviewing/trusting
the hook configuration in its hooks UI before it executes new hooks.

| Agent | Hook registration | Skill discovery |
| --- | --- | --- |
| Copilot CLI / ACP | `~/.copilot/hooks/write-gate.json` | `~/.copilot/skills/` and `~/.agents/skills/` |
| Codex CLI / ACP adapter | `$CODEX_HOME/hooks.json` (default `~/.codex`) | `~/.agents/skills/` |
| Claude Code | `$CLAUDE_CONFIG_DIR/settings.json` (default `~/.claude`) | `~/.claude/skills/` |

`~/.agents/hooks/write-gate.mjs` remains a compatibility link for old Copilot
registrations. The new stable command path is `~/.agent/hooks/write-gate.mjs`.
The hook uses a shared Neovim callback (`qvd808.custom.agent_gate`), retaining
the existing changed-file viewer and Copilot mappings.

## Gate behavior and dependencies

`dependencies.json` tracks the tools actually referenced by the config:

| Group | Tools |
| --- | --- |
| Agent runtime | Node.js 20+, Git, Zenity |
| Neovim / plugin setup | Neovim 0.11+, ripgrep (`rg`), make, a C compiler, curl or wget, tar, gzip, unzip, npm, Python 3, fd or find |
| Optional editor integrations | fd/fdfind, pylint, Go/Rust toolchains, clipboard programs, WSL's explorer.exe |
| Configured language servers | lua-language-server, pyright-langserver, clangd, gopls, rust-analyzer |
| Optional clients/tests | tmux, agent CLIs, Xvfb, xdotool |

The doctor checks PATH and, for Mason-managed tools, the Neovim data directory's
`mason/bin` folder. `XDG_DATA_HOME` and `NVIM_APPNAME` are respected. It reports
the resolved server paths, tests executable/version probes where declared, and
accepts alternatives such as gcc/clang. Missing optional tools or language servers
are reported without failing the overall check. Language servers are requested
by the existing Mason configuration; use `:Mason` and `:checkhealth` inside
Neovim to inspect package, provider, parser, and plugin health in more detail.
Ubuntu's `fdfind` is tracked as a Telescope alternative; the custom clangd
search currently tests only `fd` before falling back to `find`.

**Zenity** (`zenity`, not `zenim`) needs a separate desktop package. A starting
set of Debian/Ubuntu system packages is:

```sh
sudo apt-get install zenity ripgrep fd-find build-essential curl tar gzip unzip python3 python3-venv
node agent-workflow/doctor.mjs
```

Install compatible Neovim and Node.js/npm versions separately. Dependency checks
report problems; they don't install system packages. Clipboard backends depend
on the session: Wayland needs `wl-copy` and `wl-paste` (`wl-clipboard` package),
while the current tmux configuration uses `xsel` or `xclip` on X11. Nerd Font
glyphs also require a suitable terminal font; that isn't an executable check.

Zenity needs a reachable X11/Wayland display. A missing executable or display
means no GUI prompt; the existing chat-phrase fallback remains in effect.
The doctor reports missing dependencies and display environment variables;
a display variable alone does not prove the display can be reached.

Existing `~/.copilot/write-gate/` state is reused. New installations use
`${XDG_STATE_HOME:-~/.local/state}/agent-workflow/write-gate/`; `WRITE_GATE_HOME`
overrides either location. State stays outside the repo and linked skill tree.
The original default is **log**: would-be denials are logged, without blocking
or opening dialogs. To use the gate, put `deny` in the state's `mode` file.
The installer deliberately preserves your existing mode.

In deny mode, repo edits without an approved plan/chat marker open a Zenity
entry box. The phrase is:

> For the love of everything, please edit, please help me

The wrong phrase or dismissing the dialog denies the operation. Approval markers
are scoped to the agent and session and revoked by the next user prompt. Hooks
emit no explicit allow response, so the agent's own approval system still applies.
The existing plan grant, privileged-command rules, and allowlist are unchanged.
This remains the existing best-effort gate: it fails open on internal errors
and does not detect writes hidden inside interpreters or arbitrary scripts.

## Other agents / ACP clients

ACP transports chat, tool activity, and permission requests; it doesn't install
arbitrary pre-tool hooks or ensure every write requests permission. Finding this
directory is enough to read skills, but isn't enough to enforce a gate.

A new agent needs a supported pre-tool hook (or a client-owned execution
boundary) that calls the shared script with JSON on stdin:

```sh
node ~/.agent/hooks/write-gate.mjs prompt --agent=my-agent
node ~/.agent/hooks/write-gate.mjs tool --agent=my-agent
node ~/.agent/hooks/write-gate.mjs done --agent=my-agent
```

Common native hook fields (`session_id`, `tool_name`, `tool_input`, `cwd`),
Copilot fields (`sessionId`, `toolName`, `toolArgs`), Copilot tool batches,
and ACP `toolCall.rawInput` are accepted. Codex and Claude get their required
`hookSpecificOutput` envelope; other clients get the original generic
`permissionDecision` response and must map it to their own protocol.
Post-tool ACP notifications alone cannot block an action that already ran.

## Tests

```sh
node --test agent-workflow/install.test.mjs agent-workflow/doctor.test.mjs agent-workflow/.agents/hooks/*.test.mjs
node --test nvim/copilot-workflow/*.test.mjs
# Real Zenity window, typed wrong/correct phrases, isolated from your desktop:
# Debian/Ubuntu test dependencies: sudo apt-get install xvfb xdotool zenity
RUN_ZENITY_TESTS=1 node --test agent-workflow/zenity.test.mjs
# Actual Codex CLI + installed native hooks + real Zenity (local fake model; no login/API spend):
RUN_CODEX_HOOK_TESTS=1 node --test agent-workflow/zenity.test.mjs
```

The normal tests cover all three payload/decision adapters, actual command
invocation of a fake Zenity, session isolation, plans, protected state, Copilot
batches, and installer idempotence. The opt-in GUI test uses a real Zenity
window with a Codex pre-tool payload. The native Codex test goes further: it
installs hooks into a temporary home, starts the actual Codex CLI against a
local fake Responses server, and checks that a denied write never creates the
file while an approved write does. Both use a private authenticated virtual
display and require no agent login or paid model call. The native test uses
Codex's hook-trust bypass only for the generated test hooks in that temporary
home; normal installation leaves Codex trust checks enabled.

Hook schemas: [Codex](https://learn.chatgpt.com/docs/hooks),
[Claude Code](https://code.claude.com/docs/en/hooks).
