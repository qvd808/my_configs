-- Verification strategies.
--
-- A state that writes code has no idea whether the code is any good. This is
-- the piece that produces a deterministic pass/fail so a retry can be driven by
-- a real failure message instead of the model's opinion of its own work.
--
-- Which strategy applies is the user's call, not something to infer: only they
-- know whether "correct" means it compiles, it runs, it passes a suite, or it
-- looks right on screen.
local M = {}

M.MODES = {
  { id = "run",    label = "Run it",              hint = "python, lua, node, ruby, bash" },
  { id = "build",  label = "Compile it",          hint = "c, c++, go, rust, zig" },
  { id = "test",   label = "Run a test command",  hint = "you give the command" },
  { id = "lsp",    label = "LSP diagnostics",     hint = "type errors from the language server" },
  { id = "lint",   label = "Lint",                hint = "nvim-lint for this filetype" },
  { id = "visual", label = "Start it, I'll look", hint = "servers and apps - you judge" },
  { id = "none",   label = "Just show the code",  hint = "no verification" },
}

-- Language -> how to execute. Only entries whose tool is actually installed are
-- offered, so we never propose a check that cannot run.
local RUNNERS = {
  lua        = { "nvim", "-l", "%s" },       -- no standalone lua here; nvim -l works
  python     = { "python3", "%s" },
  javascript = { "node", "%s" },
  ruby       = { "ruby", "%s" },
  sh         = { "bash", "%s" },
  bash       = { "bash", "%s" },
}

local BUILDERS = {
  c    = { "gcc", "-Wall", "-Wextra", "-fsyntax-only", "%s" },
  cpp  = { "g++", "-Wall", "-Wextra", "-fsyntax-only", "%s" },
  go   = { "go", "vet", "%s" },
  rust = { "rustc", "--edition=2021", "--emit=metadata", "-o", "/dev/null", "%s" },
  zig  = { "zig", "ast-check", "%s" },
}

local EXT = {
  lua = "lua", python = "py", javascript = "js", ruby = "rb", sh = "sh", bash = "sh",
  c = "c", cpp = "cpp", go = "go", rust = "rs", zig = "zig",
}

-- Modes that need the code in a real buffer first (diagnostics attach there).
M.NEEDS_BUFFER = { lsp = true, lint = true }

local function have(cmd)
  return vim.fn.executable(cmd) == 1
end

--- Ensure path is loaded so filetype / LSP / lint can see it.
function M.buf_for(path)
  if not path or path == "" then
    return nil
  end
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  if vim.bo[buf].filetype == "" then
    local ft = vim.filetype.match({ buf = buf })
    if ft then
      vim.bo[buf].filetype = ft
    end
  end
  return buf
end

-- ---------------------------------------------------------------------------
-- Availability. Shown to the user before they pick a mode.
-- ---------------------------------------------------------------------------

--- @return boolean ready, string detail
function M.lsp_status(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false, "no buffer"
  end
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if #clients == 0 then
    return false, "no LSP client attached to this buffer"
  end
  local names = {}
  for _, c in ipairs(clients) do
    names[#names + 1] = c.name
  end
  return true, table.concat(names, ", ")
end

--- Which nvim-lint linters are configured and actually executable for ft.
--- @return boolean ready, string detail, string[]|nil ready_names
function M.lint_status(ft, bufnr)
  local ok, lint = pcall(require, "lint")
  if not ok then
    return false, "nvim-lint not loaded", nil
  end
  ft = ft ~= "" and ft or (bufnr and vim.bo[bufnr].filetype) or ""
  local configured = lint.linters_by_ft[ft]
  if not configured or #configured == 0 then
    return false, "no linter configured for filetype '" .. (ft ~= "" and ft or "?") .. "'", nil
  end

  local ready, missing = {}, {}
  for _, name in ipairs(configured) do
    local linter = lint.linters[name]
    local cmd = name
    if type(linter) == "table" then
      cmd = linter.cmd or name
    elseif type(linter) == "function" then
      local resolved = linter()
      if type(resolved) == "table" and resolved.cmd then
        cmd = resolved.cmd
      end
    end
    if type(cmd) == "table" then
      cmd = cmd[1]
    end
    if have(tostring(cmd)) then
      ready[#ready + 1] = name
    else
      missing[#missing + 1] = name .. " (" .. tostring(cmd) .. " not installed)"
    end
  end

  if #ready == 0 then
    return false, table.concat(missing, "; "), nil
  end
  local detail = table.concat(ready, ", ")
  if #missing > 0 then
    detail = detail .. "; missing: " .. table.concat(missing, "; ")
  end
  return true, detail, ready
end

--- One-line status for the verification prompt.
function M.status_line(ft, bufnr)
  local lsp_ok, lsp_msg = M.lsp_status(bufnr)
  local lint_ok, lint_msg = M.lint_status(ft, bufnr)
  return ("LSP: %s | Lint: %s"):format(
    lsp_ok and ("ready (" .. lsp_msg .. ")") or ("unavailable (" .. lsp_msg .. ")"),
    lint_ok and ("ready (" .. lint_msg .. ")") or ("unavailable (" .. lint_msg .. ")"))
end

--- The mode that fits this filetype, used to order the choices sensibly.
function M.default_mode(ft)
  if BUILDERS[ft] and have(BUILDERS[ft][1]) then
    return "build"
  end
  if RUNNERS[ft] and have(RUNNERS[ft][1]) then
    return "run"
  end
  return "test"
end

--- Choices for this filetype/buffer. Unavailable run/build/lsp/lint are dropped
--- from the selectable list; status_line still reports why.
function M.choices(ft, bufnr)
  local default = M.default_mode(ft)
  local out, seen = {}, {}
  local function push(id, hint_override)
    for _, m in ipairs(M.MODES) do
      if m.id == id and not seen[id] then
        seen[id] = true
        local copy = { id = m.id, label = m.label, hint = hint_override or m.hint }
        out[#out + 1] = copy
      end
    end
  end

  push(default)
  for _, m in ipairs(M.MODES) do
    local usable = true
    local hint
    if m.id == "run" then
      usable = RUNNERS[ft] ~= nil and have(RUNNERS[ft][1])
    elseif m.id == "build" then
      usable = BUILDERS[ft] ~= nil and have(BUILDERS[ft][1])
    elseif m.id == "lsp" then
      local ok, detail = M.lsp_status(bufnr)
      usable = ok
      hint = detail
    elseif m.id == "lint" then
      local ok, detail = M.lint_status(ft, bufnr)
      usable = ok
      hint = detail
    end
    if usable then
      push(m.id, hint)
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Temp-file runners (run / build / test)
-- ---------------------------------------------------------------------------

local function write_temp(code, ft)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/candidate." .. (EXT[ft] or "txt")
  vim.fn.writefile(vim.split(code, "\n"), path)
  return path
end

local function expand(template, path)
  local out = {}
  for _, part in ipairs(template) do
    out[#out + 1] = part == "%s" and path or part
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Buffer diagnostics (lsp / lint)
-- ---------------------------------------------------------------------------

local SEV_NAME = {
  [vim.diagnostic.severity.ERROR] = "ERROR",
  [vim.diagnostic.severity.WARN]  = "WARN",
  [vim.diagnostic.severity.INFO]  = "INFO",
  [vim.diagnostic.severity.HINT]  = "HINT",
}

local function format_diags(diags, bufnr)
  local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":.")
  local lines = {}
  for _, d in ipairs(diags) do
    local sev = SEV_NAME[d.severity] or "?"
    local src = d.source and (" (" .. d.source .. ")") or ""
    lines[#lines + 1] = ("%s:%d:%d [%s] %s%s"):format(
      name, (d.lnum or 0) + 1, (d.col or 0) + 1, sev, d.message or "", src)
  end
  return table.concat(lines, "\n")
end

--- Diagnostics that should fail verification (ERROR + WARN).
local function failing_diags(bufnr, filter)
  local all = vim.diagnostic.get(bufnr, {
    severity = { min = vim.diagnostic.severity.WARN },
  })
  if not filter then
    return all
  end
  local out = {}
  for _, d in ipairs(all) do
    if filter(d) then
      out[#out + 1] = d
    end
  end
  return out
end

local function is_lsp_diag(d)
  -- nvim-lint sets namespace; LSP diags usually carry a client-ish source and
  -- are not under the lint namespace. Prefer: anything not from nvim_lint.
  local ns = d.namespace and vim.diagnostic.get_namespace(d.namespace)
  if ns and ns.name and ns.name:find("lint", 1, true) then
    return false
  end
  return true
end

local function is_lint_diag(d)
  local ns = d.namespace and vim.diagnostic.get_namespace(d.namespace)
  if ns and ns.name and ns.name:find("lint", 1, true) then
    return true
  end
  -- fallback: sources that match configured linter names are often set by lint
  local src = (d.source or ""):lower()
  return src:find("ruff", 1, true)
    or src:find("eslint", 1, true)
    or src:find("yamllint", 1, true)
    or src:find("golangci", 1, true)
end

--- Wait until LSP has had a chance to publish after a buffer edit.
local function wait_lsp(bufnr, cb)
  local settled = false
  local au
  local function finish()
    if settled then
      return
    end
    settled = true
    if au then
      pcall(vim.api.nvim_del_autocmd, au)
    end
    cb(failing_diags(bufnr, is_lsp_diag))
  end

  au = vim.api.nvim_create_autocmd("DiagnosticChanged", {
    buffer = bufnr,
    callback = function()
      -- debounce: servers often fire more than once
      vim.defer_fn(finish, 200)
    end,
  })
  -- Always settle: quiet buffers (no new diags) must not hang the workflow.
  vim.defer_fn(finish, 2000)
end

--- Run nvim-lint and wait for it to finish.
local function wait_lint(bufnr, ft, cb)
  local ok, lint = pcall(require, "lint")
  if not ok then
    return cb(nil, "nvim-lint not loaded")
  end
  local ready_ok, detail, names = M.lint_status(ft, bufnr)
  if not ready_ok or not names or #names == 0 then
    return cb(nil, detail)
  end

  -- try_lint must run on the main loop with the target as current buffer so
  -- linters that read bufnr/name see the right file.
  local prev = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_buf(bufnr)
  lint.try_lint(names)
  if vim.api.nvim_buf_is_valid(prev) then
    pcall(vim.api.nvim_set_current_buf, prev)
  end

  local started = vim.uv.hrtime()
  local function poll()
    local running = {}
    if type(lint.get_running) == "function" then
      running = lint.get_running(bufnr) or lint.get_running() or {}
    end
    if #running > 0 and (vim.uv.hrtime() - started) / 1e6 < 15000 then
      return vim.defer_fn(poll, 100)
    end
    cb(failing_diags(bufnr, is_lint_diag), nil)
  end
  vim.defer_fn(poll, 50)
end

-- ---------------------------------------------------------------------------
-- Public run
-- ---------------------------------------------------------------------------

--- Runs the chosen verification.
--- @param opts table mode, ft, code, command?, bufnr? (required for lsp/lint)
--- @param cb fun(ok: boolean|nil, report: string)  ok=nil means "not decidable here"
function M.run(opts, cb)
  local mode, ft, code = opts.mode, opts.ft or "", opts.code

  if mode == "none" then
    return cb(nil, "no verification requested")
  end

  if mode == "visual" then
    -- Deliberately not judged here. Starting a server and deciding it looks
    -- right is a human check; reporting a fake pass would be worse than none.
    return cb(nil, "start it yourself and look:\n  " .. (opts.command or "<no command given>"))
  end

  if mode == "lsp" then
    local bufnr = opts.bufnr
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return cb(nil, "no buffer to check with LSP")
    end
    local ready, detail = M.lsp_status(bufnr)
    if not ready then
      return cb(nil, "LSP unavailable: " .. detail)
    end
    return wait_lsp(bufnr, function(diags)
      if #diags == 0 then
        return cb(true, "ok (no LSP warnings/errors)")
      end
      cb(false, format_diags(diags, bufnr))
    end)
  end

  if mode == "lint" then
    local bufnr = opts.bufnr
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return cb(nil, "no buffer to lint")
    end
    return wait_lint(bufnr, ft, function(diags, err)
      if err then
        return cb(nil, err)
      end
      if not diags or #diags == 0 then
        return cb(true, "ok (no lint warnings/errors)")
      end
      cb(false, format_diags(diags, bufnr))
    end)
  end

  local cmd, path
  if mode == "test" then
    if not opts.command or opts.command == "" then
      return cb(false, "no test command given")
    end
    path = write_temp(code, ft)
    cmd = { "sh", "-c", opts.command }
  elseif mode == "build" then
    local t = BUILDERS[ft]
    if not t or not have(t[1]) then
      return cb(nil, "no compiler available for filetype '" .. ft .. "'")
    end
    path = write_temp(code, ft)
    cmd = expand(t, path)
  elseif mode == "run" then
    local t = RUNNERS[ft]
    if not t or not have(t[1]) then
      return cb(nil, "no runner available for filetype '" .. ft .. "'")
    end
    path = write_temp(code, ft)
    cmd = expand(t, path)
  else
    return cb(nil, "unknown verification mode: " .. tostring(mode))
  end

  vim.system(cmd, { text = true, cwd = vim.fs.dirname(path), timeout = 30000 }, function(res)
    vim.schedule(function()
      local output = vim.trim((res.stdout or "") .. "\n" .. (res.stderr or ""))
      -- strip the temp path so the model sees a stable filename across retries
      output = output:gsub(vim.pesc(path), "candidate." .. (EXT[ft] or "txt"))
      if res.code == 0 then
        cb(true, output ~= "" and output or "ok")
      else
        cb(false, ("exit %d\n%s"):format(res.code, output ~= "" and output or "(no output)"))
      end
    end)
  end)
end

return M
