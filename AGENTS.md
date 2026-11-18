# Repository navigation

Shared agent hooks and skills live in `agent-workflow/`. Read
`agent-workflow/README.md` for setup, dependency checks, and agent adapters.
`init.sh` installs stable links under `~/.agent` and agent-specific hook entries.
Edit the shared source in this repository so installed links receive updates.

Neovim's existing Copilot UI and workflow controller live in
`nvim/lua/qvd808/custom/` and `nvim/copilot-workflow/`. Preserve their behavior
when changing the shared gate. ACP transport and native lifecycle hooks are
separate integration points.
