# Tools

The four things the agent is allowed to do. Adopted from pi's built-in set.

Nothing here describes an agent loop — how these get called is a separate design.

| Tool | Purpose |
|---|---|
| `read` | Get file contents |
| `write` | Replace a whole file, or create one |
| `edit` | Replace one exact span inside a file |
| `bash` | Run a shell command |

`read`, `write` and `edit` are implementable on the standard Neovim API. Only `bash` needs a
subprocess.

---

### `read(path, from?, to?)`

`from`/`to` are 1-indexed and inclusive. Both optional — omitted means the whole file.

They exist to save context, not time. Reading a 20,000-line file takes ~1 ms; *sending* it is
~61,000 tokens, which does not fit in a 64k window. One function is ~31 tokens.

Read through the buffer when the file is already open (`nvim_buf_get_lines`) — it is the only way to
see unsaved changes.

### `write(path, content)`

Replaces the entire file, creating it if absent.

### `edit(path, oldText, newText)`

`oldText` must match **exactly once**. Zero or multiple matches is an error, not a guess.

Uniqueness is what makes the edit self-verifying: a line-number edit silently corrupts the file when
the agent's view is one revision stale, while a string edit simply fails.

### `bash(command, timeout?)`

Runs in the project root, returns stdout and stderr.

This is the tool that turns a scoped file agent into an unscoped shell agent — it can do everything
the other three can, and everything else besides. Worth gating separately from the file tools.

---

### Later

Not needed yet, noted so they are not re-derived:

- `read` truncation caps, so a large file cannot blow the context window in one call.
- Path scoping to the project root, checked after `realpath` so an outward symlink does not defeat it.
- Stripping a leading `@` from paths — models routinely include it from `@file` mention syntax.
