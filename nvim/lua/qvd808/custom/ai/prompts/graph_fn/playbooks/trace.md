## Playbook: call-flow / hierarchy
- Reconstruct the path: callers → focus → callees (and file boundaries).
- Note globals/APIs that cross the boundary (vim.*, require, etc.).
- If hierarchy is incomplete (e.g. lua_ls), say so and rely on graph + grep.
