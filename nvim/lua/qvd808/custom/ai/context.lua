-- Context harness for /write.
--
-- Deterministic lookups the model does not get to choose: pull identifiers out
-- of the goal, then resolve them with search (rg → grep → Lua/vim.fs) plus LSP
-- symbol tree / hover. Results fold into the prompt once before emit_code.
local M = {}

local MAX_NAMES       = 6
local MAX_GREP_HITS   = 8
local MAX_FILES_SCAN  = 800   -- Lua walk cap when rg/grep are absent
local MAX_SYMBOLS     = 6
local MAX_HOVERS      = 4
local HOVER_MAX_CHARS = 1200
local SNIPPET_LINES   = 12
local LSP_TIMEOUT_MS  = 1500
local READ_MAX_LINES  = 4000
local GREP_TIMEOUT_MS = 4000

-- Words that show up in goals but are almost never symbols worth resolving.
local STOP = {
  a = true, an = true, the = true, ["and"] = true, ["or"] = true, to = true, ["for"] = true,
  ["of"] = true, ["in"] = true, on = true, ["with"] = true, ["from"] = true, into = true,
  that = true, ["this"] = true, it = true, ["is"] = true, be = true, ["as"] = true,
  should = true, would = true, could = true, can = true, will = true,
  write = true, add = true, create = true, make = true, implement = true,
  update = true, fix = true, refactor = true, use = true, using = true,
  call = true, calling = true, ["function"] = true, method = true, class = true,
  code = true, file = true, buffer = true, ["new"] = true, please = true,
  ["return"] = true, returns = true, take = true, takes = true, get = true,
  set = true, put = true, based = true, like = true, just = true, also = true,
}

-- ---------------------------------------------------------------------------
-- Name extraction
-- ---------------------------------------------------------------------------

--- Identifiers mentioned in the goal: CamelCase, snake_case, dotted paths,
--- backtick-quoted names, and explicit call/use mentions. Ordered by first
--- appearance, capped.
function M.extract_names(goal)
  local seen, out = {}, {}
  local function push(raw, force)
    local name = (raw or ""):gsub("^[%.:]+", ""):gsub("[%.:]+$", "")
    if name == "" or #name < 2 or #name > 64 then
      return
    end
    if name:match("^%d") then
      return
    end
    local key = name:lower()
    if STOP[key] or seen[key] then
      return
    end
    -- ALL_CAPS noise ("API", "HTTP") unless the goal marked it as code.
    if not force and name:match("^[A-Z][A-Z0-9]*$") and #name <= 5 then
      return
    end
    -- Bare prose words stay out unless the goal marked them as code.
    if not force and not (name:find("[_%.]") or name:match("%u") or name:match("^[a-z]+[A-Z]")) then
      return
    end
    seen[key] = true
    out[#out + 1] = name
  end

  goal = goal or ""
  for name in goal:gmatch("`([%w_%.]+)`") do
    push(name, true)
  end
  for name in goal:gmatch("([%a_][%w_%.]*)%s*%(") do
    push(name, true)
  end
  for name in goal:gmatch("[Uu]se%s+([%a_][%w_%.]*)") do
    push(name, true)
  end
  for name in goal:gmatch("[Cc]all[s]?%s+([%a_][%w_%.]*)") do
    push(name, true)
  end
  for name in goal:gmatch("[%a_][%w_%.]*") do
    if name:find("[_%.]") or name:match("%u") then
      push(name, false)
    end
  end

  if #out > MAX_NAMES then
    out = vim.list_slice(out, 1, MAX_NAMES)
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Project search: rg → grep → Lua (vim.fs + matchstrlist)
--
-- Prefer fast external tools when present; fall back to in-process Neovim APIs
-- so Windows / minimal installs still work with no extra binaries.
-- ---------------------------------------------------------------------------

local PRUNE = {
  [".git"] = true, ["node_modules"] = true, [".venv"] = true, ["venv"] = true,
  ["__pycache__"] = true, ["target"] = true, ["dist"] = true, ["build"] = true,
  [".next"] = true, [".cache"] = true, ["vendor"] = true, [".aicompanion"] = true,
}

local SKIP_EXT = {
  png = true, jpg = true, jpeg = true, gif = true, webp = true, ico = true,
  pdf = true, zip = true, gz = true, tar = true, bz2 = true, xz = true,
  o = true, a = true, so = true, dll = true, exe = true, class = true,
  pyc = true, pyo = true, wasm = true, lock = true,
}

local function project_root()
  local found = vim.fs.find(".git", { path = vim.fn.getcwd(), upward = true })[1]
  return found and vim.fs.dirname(found) or vim.fn.getcwd()
end

local function exe(bin)
  return vim.fn.executable(bin) == 1
end

local function parse_path_line_text(stdout, root)
  local hits = {}
  root = vim.fs.normalize(root or project_root())
  for line in (stdout or ""):gmatch("[^\r\n]+") do
    local path, lnum, text = line:match("^(.+):(%d+):%d+:(.*)$")
    if not path then
      path, lnum, text = line:match("^(.+):(%d+):(.*)$")
    end
    if path and lnum and text then
      local norm = vim.fs.normalize(path)
      local rel = norm
      if norm:sub(1, #root) == root then
        rel = norm:sub(#root + 2)
      end
      hits[#hits + 1] = {
        path = vim.fn.fnamemodify(rel, ":."),
        line = tonumber(lnum),
        text = vim.trim(text),
      }
      if #hits >= MAX_GREP_HITS then
        break
      end
    end
  end
  return hits
end

local function via_rg(pattern)
  if not exe("rg") then
    return nil, "not installed"
  end
  local res = vim.system({
    "rg", "--json", "-n", "-S", "-F", "-m", tostring(MAX_GREP_HITS),
    "--hidden", "--glob", "!.git", "--glob", "!node_modules",
    "--glob", "!.venv", "--glob", "!venv", "--glob", "!.aicompanion",
    "-e", pattern, ".",
  }, { text = true, cwd = project_root(), timeout = GREP_TIMEOUT_MS }):wait()
  if res.code ~= 0 and res.code ~= 1 then
    return nil, ("exited %d"):format(res.code)
  end
  local hits = {}
  for line in (res.stdout or ""):gmatch("[^\n]+") do
    local ok, row = pcall(vim.json.decode, line)
    if ok and row and row.type == "match" and row.data then
      local p = row.data.path and row.data.path.text
      local ln = row.data.line_number
      local t = row.data.lines and row.data.lines.text
      if p and ln and t then
        hits[#hits + 1] = {
          path = vim.fn.fnamemodify(p, ":."),
          line = ln,
          text = vim.trim(t),
        }
      end
      if #hits >= MAX_GREP_HITS then
        break
      end
    end
  end
  return hits
end

local function via_grep(pattern)
  if not exe("grep") then
    return nil, "not installed"
  end
  local res = vim.system({
    "grep", "-R", "-n", "-I", "-F",
    "--exclude-dir=.git", "--exclude-dir=node_modules",
    "--exclude-dir=.venv", "--exclude-dir=venv",
    "--exclude-dir=.aicompanion",
    "-e", pattern, ".",
  }, { text = true, cwd = project_root(), timeout = GREP_TIMEOUT_MS }):wait()
  if res.code ~= 0 and res.code ~= 1 then
    return nil, ("exited %d"):format(res.code)
  end
  return parse_path_line_text(res.stdout)
end

local function should_skip_file(path)
  local ext = path:match("%.([%w]+)$")
  return ext and SKIP_EXT[ext:lower()] or false
end

local function lines_of(abs)
  local norm = vim.fs.normalize(abs)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b)
      and vim.bo[b].buftype == ""
      and vim.fs.normalize(vim.api.nvim_buf_get_name(b)) == norm then
      return vim.api.nvim_buf_get_lines(b, 0, -1, false)
    end
  end
  local ok, lines = pcall(vim.fn.readfile, abs, "", READ_MAX_LINES)
  if ok then
    return lines
  end
  return nil
end

local function match_lines(lines, needle)
  if not lines or needle == "" then
    return {}
  end
  local pat = "\\V" .. vim.fn.escape(needle, "\\")
  local ok, matches = pcall(vim.fn.matchstrlist, lines, pat)
  local out = {}
  if ok and type(matches) == "table" then
    for _, m in ipairs(matches) do
      out[#out + 1] = { idx = (m.idx or 0) + 1, text = m.text }
    end
    return out
  end
  for i, line in ipairs(lines) do
    if line:find(needle, 1, true) then
      out[#out + 1] = { idx = i, text = line }
    end
  end
  return out
end

local function project_files()
  local root = project_root()
  local files = {}

  local function walk(dir)
    if #files >= MAX_FILES_SCAN then
      return
    end
    local ok, iter = pcall(vim.fs.dir, dir)
    if not ok or not iter then
      return
    end
    for name, ftype in iter do
      if #files >= MAX_FILES_SCAN then
        return
      end
      local abs = vim.fs.joinpath(dir, name)
      if ftype == "directory" then
        if not PRUNE[name] then
          walk(abs)
        end
      elseif ftype == "file" and not should_skip_file(name) then
        files[#files + 1] = abs
      end
    end
  end

  walk(root)
  return files, root
end

--- In-process fallback: vim.fs walk + matchstrlist (no external binary).
local function via_lua(pattern)
  local files, root = project_files()
  local hits = {}
  local root_norm = vim.fs.normalize(root)

  for _, abs in ipairs(files) do
    local lines = lines_of(abs)
    if lines then
      for _, m in ipairs(match_lines(lines, pattern)) do
        local norm = vim.fs.normalize(abs)
        local rel = norm
        if norm:sub(1, #root_norm) == root_norm then
          rel = norm:sub(#root_norm + 2)
        end
        hits[#hits + 1] = {
          path = vim.fn.fnamemodify(rel, ":."),
          line = m.idx,
          text = vim.trim(lines[m.idx] or m.text or ""),
        }
        if #hits >= MAX_GREP_HITS then
          return hits
        end
      end
    end
  end
  return hits
end

--- @return table[] hits { path, line, text }, string|nil err, string backend
function M.grep(name)
  if not name or name == "" then
    return {}, "empty pattern", "none"
  end

  local chain = {
    { "rg", via_rg },
    { "grep", via_grep },
    { "lua", via_lua },
  }
  local errors = {}
  for _, item in ipairs(chain) do
    local id, fn = item[1], item[2]
    local hits, err = fn(name)
    if hits then
      return hits, nil, id
    end
    errors[#errors + 1] = id .. ": " .. tostring(err)
  end
  return {}, table.concat(errors, "; "), "none"
end

-- ---------------------------------------------------------------------------
-- LSP: document symbols (scope), workspace symbols, hover
-- ---------------------------------------------------------------------------

local function has_method(bufnr, method)
  for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    if c:supports_method(method) then
      return true
    end
  end
  return false
end

local function range_of(sym)
  if sym.range then
    return sym.range
  end
  if sym.location and sym.location.range then
    return sym.location.range
  end
  return nil
end

local function uri_of(sym)
  if sym.location and sym.location.uri then
    return sym.location.uri
  end
  return nil
end

local function flatten_symbols(items, acc, uri)
  acc = acc or {}
  for _, s in ipairs(items or {}) do
    local r = range_of(s)
    if s.name and r then
      acc[#acc + 1] = {
        name = s.name,
        kind = s.kind,
        range = r,
        uri = uri_of(s) or uri,
        detail = s.detail,
      }
    end
    if s.children then
      flatten_symbols(s.children, acc, uri_of(s) or uri)
    end
  end
  return acc
end

local function collect_document_symbols(bufnr)
  if not has_method(bufnr, "textDocument/documentSymbol") then
    return nil
  end
  local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
  local results = vim.lsp.buf_request_sync(bufnr, "textDocument/documentSymbol", params, LSP_TIMEOUT_MS)
  if not results then
    return nil
  end
  local uri = vim.uri_from_bufnr(bufnr)
  local acc = {}
  for _, res in pairs(results) do
    if res.result then
      flatten_symbols(res.result, acc, uri)
    end
  end
  return acc
end

--- Smallest document symbol enclosing `row` (0-indexed). Used by write.scope.
--- @return number|nil sr, number|nil er, string|nil kind_label
function M.document_scope(bufnr, row)
  local syms = collect_document_symbols(bufnr)
  if not syms or #syms == 0 then
    return nil
  end
  local best
  for _, s in ipairs(syms) do
    local r = s.range
    local sr, er = r.start.line, r["end"].line
    if sr <= row and row <= er then
      local span = er - sr
      if not best or span < best.span then
        best = { sr = sr, er = er, name = s.name, kind = s.kind, span = span }
      end
    end
  end
  if not best then
    return nil
  end
  local kinds = vim.lsp.protocol.SymbolKind
  local label = best.name
  for name, id in pairs(kinds) do
    if id == best.kind then
      label = name:lower() .. " " .. best.name
      break
    end
  end
  return best.sr, best.er, label
end

local function workspace_symbols(bufnr, query)
  if not has_method(bufnr, "workspace/symbol") then
    return {}
  end
  local results = vim.lsp.buf_request_sync(bufnr, "workspace/symbol", { query = query }, LSP_TIMEOUT_MS)
  if not results then
    return {}
  end
  local acc = {}
  for _, res in pairs(results) do
    if res.result then
      flatten_symbols(res.result, acc, nil)
    end
  end
  -- Prefer exact / suffix matches on the queried name.
  local q = query:lower()
  table.sort(acc, function(a, b)
    local an, bn = a.name:lower(), b.name:lower()
    local as = (an == q and 0) or (an:sub(-#q) == q and 1) or 2
    local bs = (bn == q and 0) or (bn:sub(-#q) == q and 1) or 2
    if as ~= bs then
      return as < bs
    end
    return #an < #bn
  end)
  if #acc > MAX_SYMBOLS then
    acc = vim.list_slice(acc, 1, MAX_SYMBOLS)
  end
  return acc
end

local function markdown_of_hover(result)
  if not result or not result.contents then
    return nil
  end
  local lines = vim.lsp.util.convert_input_to_markdown_lines(result.contents)
  local text = vim.trim(table.concat(lines, "\n"))
  if text == "" then
    return nil
  end
  if #text > HOVER_MAX_CHARS then
    text = text:sub(1, HOVER_MAX_CHARS) .. "\n…"
  end
  return text
end

local function hover_at(uri, line, character)
  local path = vim.uri_to_fname(uri)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  if not has_method(buf, "textDocument/hover") then
    return nil
  end
  local params = {
    textDocument = { uri = uri },
    position = { line = line, character = character },
  }
  local results = vim.lsp.buf_request_sync(buf, "textDocument/hover", params, LSP_TIMEOUT_MS)
  if not results then
    return nil
  end
  for _, res in pairs(results) do
    local md = markdown_of_hover(res.result)
    if md then
      return md
    end
  end
  return nil
end

local function snippet_at(path, line1)
  local abs = path
  if not abs:match("^/") then
    abs = project_root() .. "/" .. path
  end
  if vim.fn.filereadable(abs) ~= 1 then
    return nil
  end
  local buf = vim.fn.bufadd(abs)
  vim.fn.bufload(buf)
  local total = vim.api.nvim_buf_line_count(buf)
  local from = math.max(1, line1)
  local to = math.min(total, from + SNIPPET_LINES - 1)
  local lines = vim.api.nvim_buf_get_lines(buf, from - 1, to, false)
  return table.concat(lines, "\n"), from, to
end

-- ---------------------------------------------------------------------------
-- Public enrich
-- ---------------------------------------------------------------------------

--- Resolve names in `goal` against grep + LSP. Returns markdown and a short label.
--- @param goal string
--- @param bufnr number|nil
--- @return string digest, string label
function M.enrich(goal, bufnr)
  local names = M.extract_names(goal)
  if #names == 0 then
    return "", "no symbol hints in goal"
  end

  local sections = {}
  local used_grep, used_lsp, used_hover = 0, 0, 0
  local hovered = 0

  sections[#sections + 1] = "=== related symbols (resolved from the goal) ==="
  sections[#sections + 1] = "names: " .. table.concat(names, ", ")

  for _, name in ipairs(names) do
    local block = { "--- " .. name .. " ---" }

    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      local syms = workspace_symbols(bufnr, name)
      if #syms > 0 then
        used_lsp = used_lsp + 1
        for _, s in ipairs(syms) do
          local path = s.uri and vim.fn.fnamemodify(vim.uri_to_fname(s.uri), ":.") or "?"
          local line = (s.range.start.line or 0) + 1
          local detail = s.detail and (" — " .. s.detail) or ""
          block[#block + 1] = ("symbol  %s:%d  %s%s"):format(path, line, s.name, detail)

          if hovered < MAX_HOVERS and s.uri then
            local md = hover_at(s.uri, s.range.start.line, s.range.start.character or 0)
            if md then
              hovered = hovered + 1
              used_hover = used_hover + 1
              block[#block + 1] = "hover:\n" .. md
            end
          end

          local body = snippet_at(path, line)
          if body then
            block[#block + 1] = ("snippet %s:%d:\n%s"):format(path, line, body)
          end
        end
      end
    end

    local hits, gerr, backend = M.grep(name)
    if gerr and #block == 1 then
      block[#block + 1] = "search: " .. gerr
    elseif #hits > 0 then
      used_grep = used_grep + 1
      block[#block + 1] = "search (" .. (backend or "vim") .. "):"
      for _, h in ipairs(hits) do
        block[#block + 1] = ("  %s:%d: %s"):format(h.path, h.line, h.text)
      end
    end

    if #block > 1 then
      sections[#sections + 1] = table.concat(block, "\n")
    end
  end

  if #sections <= 2 then
    return "", "looked up " .. table.concat(names, ", ") .. " (nothing found)"
  end

  local label = ("related: %s [search=%d lsp=%d hover=%d]"):format(
    table.concat(names, ", "), used_grep, used_lsp, used_hover)
  return table.concat(sections, "\n\n"), label
end

return M
