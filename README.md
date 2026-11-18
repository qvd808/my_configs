## Run this file to generate the configs
```
chmod +x init.sh
./init.sh
```

The installer also links the shared skills and write gate for Copilot, Codex,
and Claude Code. See [agent-workflow](agent-workflow/README.md) for dependencies,
hook registration, and tests. Use `./init.sh --check` to check dependencies or
`./init.sh --agents-only` to leave editor and tmux configuration alone.
