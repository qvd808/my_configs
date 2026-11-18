#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if ! command -v node >/dev/null 2>&1; then
  echo "Node.js 20+ is required to install the shared agent workflow." >&2
  exit 1
fi
node "$repo_root/agent-workflow/install.mjs" "$@"
if [[ $# == 0 ]] && command -v tmux >/dev/null 2>&1 && tmux has-session 2>/dev/null; then
  tmux source-file "$HOME/.tmux.conf"
fi
