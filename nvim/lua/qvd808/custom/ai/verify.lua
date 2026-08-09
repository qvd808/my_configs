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

local function have(cmd)
  return vim.fn.executable(cmd) == 1
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

--- Choices for this filetype, most applicable first, unavailable ones dropped.
function M.choices(ft)
  local default = M.default_mode(ft)
  local out, seen = {}, {}
  local function push(id)
    for _, m in ipairs(M.MODES) do
      if m.id == id and not seen[id] then
        seen[id] = true
        out[#out + 1] = m
      end
    end
  end
  push(default)
  for _, m in ipairs(M.MODES) do
    local usable = true
    if m.id == "run" then
      usable = RUNNERS[ft] ~= nil and have(RUNNERS[ft][1])
    elseif m.id == "build" then
      usable = BUILDERS[ft] ~= nil and have(BUILDERS[ft][1])
    end
    if usable then
      push(m.id)
    end
  end
  return out
end

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

--- Runs the chosen verification.
--- @param opts table mode, ft, code, command (for test/visual)
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
