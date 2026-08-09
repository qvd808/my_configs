-- Write workflow: one call, buffer-scoped, no project survey.
--
-- The counterpart to /plan. /plan is for changes whose blast radius you do not
-- yet know, so it pays to survey first. /write is for changes you have already
-- scoped yourself -- "this function, this file" -- where surveying the project
-- would add tokens and no information.
--
-- Context is narrowed as tightly as the editor can manage:
--
--   LSP document symbol
--     -> treesitter enclosing node
--       -> whole buffer
--
-- Then a deterministic enrich pass resolves names mentioned in the goal via
-- Neovim APIs (vim.fs walk + matchstrlist, or rg/grep when available) and LSP
-- workspace symbols / hover, so the model can see signatures of helpers it
-- should call without a tool loop.
--
-- Each rung is a fallback for the one above, because none of them is
-- guaranteed: a buffer may have no LSP client, no parser, or neither.
local provider = require("qvd808.custom.ai.provider")

local M = {}

local WHOLE_BUFFER_MAX_LINES = 800

local CODE_SCHEMA = {
  type = "object",
  properties = {
    language = { type = "string", description = "Language id for the fence, e.g. lua, python, javascript" },
    code     = { type = "string", description = "The complete code, ready to paste. No fences, no prose." },
    replaces = { type = "string", description =
      "The exact existing lines this code replaces, copied verbatim from the context, "
      .. "whitespace included. It must appear exactly once in the file. "
      .. "Omit entirely when adding something new rather than replacing." },
    notes    = { type = "string", description = "Anything the reader must know: assumptions, how to run it" },
  },
  required = { "code" },
}

local CODE_TOOL = {
  type = "function",
  ["function"] = {
    name = "emit_code",
    description = "Emit the finished code.",
    parameters = CODE_SCHEMA,
  },
}

local SYSTEM = [[
Role: Senior engineer writing one focused piece of code.

You are given a goal, the smallest slice of the buffer that contains it, and
(when available) a related-symbols section resolved from names in the goal:
grep hits, LSP symbol locations, hover/signature text, and short snippets.
Treat that section as ground truth for how to call those helpers -- inputs,
outputs, and names. Do not invent signatures that contradict it.

That slice is the whole job. Do not plan a project, do not propose files you
were not asked about, do not restructure code you cannot see.

Write the code, then call emit_code exactly once.

Rules:
- `code` is plain source, no markdown fences.
- If you are replacing a function, return the complete replacement, not a diff,
  and put the exact existing lines in `replaces` so the edit can be located.
- `replaces` must be copied verbatim from the context you were given, including
  indentation, and must occur exactly once. Omit it when adding new code.
- If the goal is ambiguous, pick the most conventional reading and record the
  assumption in `notes` rather than asking.
]]

-- ---------------------------------------------------------------------------
-- Scoping
-- ---------------------------------------------------------------------------

--- The buffer the user is actually working in: the first window whose buffer
--- is not part of the chat UI.
function M.target()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if not vim.b[buf].ai_role and vim.bo[buf].buftype == "" then
      return buf, win
    end
  end
  return nil
end

--- Smallest enclosing named node that looks like a definition.
local function treesitter_scope(buf, row)
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok or not parser then
    return nil
  end
  local ok2, trees = pcall(parser.parse, parser)
  if not ok2 or not trees or not trees[1] then
    return nil
  end
  local node = trees[1]:root():named_descendant_for_range(row, 0, row, 0)
  while node do
    local t = node:type()
    if t:find("function") or t:find("method") or t:find("class") or t:find("declaration") then
      local sr, _, er, _ = node:range()
      return sr, er, t
    end
    node = node:parent()
  end
  return nil
end

--- Returns context text and a human label describing how it was scoped.
--- The rungs are ordered most-specific first; each must tolerate the tools
--- above it being absent.
function M.scope(buf, row)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return "", "no buffer - writing from the goal alone"
  end

  local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":.")
  if name == "" then
    name = "[unnamed]"
  end
  local total = vim.api.nvim_buf_line_count(buf)
  local ctx = require("qvd808.custom.ai.context")

  -- rung 1: LSP document symbol enclosing the cursor
  local sr, er, kind = ctx.document_scope(buf, row)
  if sr then
    local lines = vim.api.nvim_buf_get_lines(buf, sr, er + 1, false)
    return ("=== %s lines %d-%d (%s) ===\n%s"):format(name, sr + 1, er + 1, kind,
      table.concat(lines, "\n")),
      ("%s:%d-%d via lsp (%s)"):format(name, sr + 1, er + 1, kind)
  end

  -- rung 2: treesitter
  sr, er, kind = treesitter_scope(buf, row)
  if sr then
    local lines = vim.api.nvim_buf_get_lines(buf, sr, er + 1, false)
    return ("=== %s lines %d-%d (%s) ===\n%s"):format(name, sr + 1, er + 1, kind,
      table.concat(lines, "\n")),
      ("%s:%d-%d via treesitter (%s)"):format(name, sr + 1, er + 1, kind)
  end

  -- rung 3: whole buffer, if it is small enough to be honest about
  if total <= WHOLE_BUFFER_MAX_LINES then
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local body = table.concat(lines, "\n")
    if vim.trim(body) == "" then
      return ("=== %s (empty) ==="):format(name), name .. " (empty buffer)"
    end
    return ("=== %s (whole file, %d lines) ===\n%s"):format(name, total, body),
      ("%s whole file (%d lines)"):format(name, total)
  end

  -- rung 4: a window around the cursor
  local from = math.max(0, row - 100)
  local to = math.min(total, row + 100)
  local lines = vim.api.nvim_buf_get_lines(buf, from, to, false)
  return ("=== %s lines %d-%d (window around cursor) ===\n%s"):format(name, from + 1, to,
    table.concat(lines, "\n")),
    ("%s:%d-%d cursor window"):format(name, from + 1, to)
end

--- Buffer slice plus related-symbol digest from the goal.
function M.context_for(goal, buf, row)
  local context, label = M.scope(buf, row)
  local related, related_label = require("qvd808.custom.ai.context").enrich(goal, buf)
  if related ~= "" then
    if context ~= "" then
      context = context .. "\n\n" .. related
    else
      context = related
    end
    label = label .. "; " .. related_label
  elseif related_label and related_label ~= "" then
    label = label .. "; " .. related_label
  end
  return context, label
end
-- ---------------------------------------------------------------------------
-- Workflow
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- Applying to a buffer
-- ---------------------------------------------------------------------------

--- Index of the unique occurrence of `needle` (a line list) inside `hay`.
--- Returns nil plus a reason when absent or ambiguous -- the uniqueness rule is
--- what makes the edit self-verifying: a stale view fails instead of clobbering.
local function locate(hay, needle)
  if #needle == 0 then
    return nil, "nothing to match"
  end
  local found
  for i = 1, #hay - #needle + 1 do
    local match = true
    for j = 1, #needle do
      if hay[i + j - 1] ~= needle[j] then
        match = false
        break
      end
    end
    if match then
      if found then
        return nil, "the replaced text appears more than once"
      end
      found = i
    end
  end
  if not found then
    return nil, "the replaced text was not found in the file"
  end
  return found
end

--- Writes through the buffer, never straight to disk, so `u` undoes it and you
--- decide when to :w.
--- @return boolean ok, string message, string old_text
function M.apply(path, replaces, code)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return false, "could not open " .. path, ""
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local new_lines = vim.split(code, "\n")

  if not replaces or vim.trim(replaces) == "" then
    local at = #lines
    local insert = {}
    if at > 0 and vim.trim(lines[at] or "") ~= "" then
      insert[#insert + 1] = ""
    end
    vim.list_extend(insert, new_lines)
    vim.api.nvim_buf_set_lines(buf, at, at, false, insert)
    return true, ("appended %d line(s) to %s"):format(#new_lines, path), ""
  end

  local needle = vim.split(replaces, "\n")
  -- models sometimes include a trailing blank from the JSON string
  while #needle > 0 and vim.trim(needle[#needle]) == "" do
    table.remove(needle)
  end

  local at, err = locate(lines, needle)
  if not at then
    return false, err .. " (" .. path .. ")", ""
  end

  vim.api.nvim_buf_set_lines(buf, at - 1, at - 1 + #needle, false, new_lines)
  return true, ("replaced lines %d-%d of %s"):format(at, at + #needle - 1, path),
    table.concat(needle, "\n")
end

local MAX_ATTEMPTS = 3

--- Open, named, ordinary buffers -- the candidate destinations.
local function candidate_files()
  local out, seen = {}, {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buftype == "" and not vim.b[b].ai_role then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" and not seen[name] then
        seen[name] = true
        out[#out + 1] = { id = name, label = vim.fn.fnamemodify(name, ":."), hint = "open buffer" }
      end
    end
  end
  out[#out + 1] = { id = "__other__", label = "Somewhere else", hint = "type a path" }
  return out
end

--- Put `old_text` back when a buffer-backed verify failed, so the next attempt
--- can still match the original `replaces` from the scoped context.
local function revert(path, old_text, bad_code)
  if old_text == nil then
    return
  end
  if old_text == "" then
    -- Pure append: strip the trailing block we just added.
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local bad = vim.split(bad_code or "", "\n")
    local n = #bad
    if n > 0 and #lines >= n then
      local start = #lines - n + 1
      local match = true
      for i = 1, n do
        if lines[start + i - 1] ~= bad[i] then
          match = false
          break
        end
      end
      -- optional leading blank we may have inserted before the append
      local from = start - 1
      if match and from >= 1 and lines[from] == "" then
        vim.api.nvim_buf_set_lines(buf, from - 1, #lines, false, {})
      elseif match then
        vim.api.nvim_buf_set_lines(buf, start - 1, #lines, false, {})
      end
    end
    return
  end
  M.apply(path, bad_code, old_text)
end

local function format_status(mode, passed, report, n)
  if passed == true then
    local status = "verified: " .. mode
    if report and report ~= "" and not report:match("^ok") then
      status = status .. "\n\n```\n" .. report .. "\n```"
      if mode == "run" or mode == "build" then
        status = status .. "\n_exit code only -- check the output is actually right_"
      end
    elseif report and report:match("^ok") then
      status = status .. " — " .. report
    end
    return status
  end
  if passed == false then
    return ("FAILED after %d attempts (%s)\n\n```\n%s\n```"):format(n, mode, report)
  end
  return report -- not decidable: visual / none / toolchain missing
end

function M.run(goal, ctx, cb, preset)
  local verify = require("qvd808.custom.ai.verify")
  preset = preset or {}

  local buf, win = M.target()
  local ft = buf and vim.bo[buf].filetype or ""
  local row = 0
  if win and vim.api.nvim_win_is_valid(win) then
    row = vim.api.nvim_win_get_cursor(win)[1] - 1
  end

  -- Filled once the destination is known: scope the target buffer and resolve
  -- symbols named in the goal (grep + LSP) before the single model call.
  local context, label = "", ""
  local totals = { calls = 0, in_tokens = 0, out_tokens = 0, ms = 0 }

  local function finish(target_path, args, code, lang, status)
    local D = require("qvd808.custom.ai.diff")
    local text

    if args._apply_failed then
      text = ("could not apply: %s\n\n```%s\n%s\n```\n\n"):format(args._apply_failed, lang, code)
    elseif verify.NEEDS_BUFFER[args._mode] then
      -- Already in the buffer from the verify step.
      text = D.render(args._old_text or "", code)
        .. "\n\n" .. (args._apply_message or ("updated " .. target_path))
        .. "  _(u to undo)_\n\n"
    else
      local applied, message, old_text = M.apply(target_path, args.replaces, code)
      if applied then
        text = D.render(old_text, code) .. "\n\n" .. message .. "  _(u to undo)_\n\n"
      else
        text = ("could not apply: %s\n\n```%s\n%s\n```\n\n"):format(message, lang, code)
      end
    end

    if args.notes and args.notes ~= "" then
      text = text .. args.notes .. "\n\n"
    end
    text = text .. status .. "\n\n_scope: " .. label .. "_"

    cb(nil, {
      text = text,
      meta = ("%.1fs - %d call(s) - %d in / %d out tok"):format(
        totals.ms / 1000, totals.calls, totals.in_tokens, totals.out_tokens),
    })
  end

  -- One attempt. Deliberately builds a *fresh* message list every time: the
  -- retry carries the previous code and the failure, not a growing transcript.
  -- That is what separates this from ReAct -- iteration without accumulation.
  local function attempt(n, target_path, mode, command, prev_code, failure)
    local user = "Goal: " .. goal .. "\n\nBuffer context:\n\n" .. context
    if failure then
      user = user .. ("\n\nYour previous attempt FAILED verification (%s).\n\nPrevious code:\n%s\n\nFailure:\n%s\n\nFix it and emit the corrected code.")
        :format(mode, prev_code, failure)
    end

    ctx.on_step("write", n == 1 and "one call, no survey" or ("attempt " .. n))

    provider.chat({
      messages = {
        { role = "system", content = SYSTEM },
        { role = "user", content = user },
      },
      tools = { CODE_TOOL },
      tool_choice = { type = "function", ["function"] = { name = "emit_code" } },
    }, function(err, choice, usage, ms)
      if err then
        return cb(err)
      end
      totals.calls = totals.calls + 1
      totals.in_tokens = totals.in_tokens + (usage.prompt_tokens or 0)
      totals.out_tokens = totals.out_tokens + (usage.completion_tokens or 0)
      totals.ms = totals.ms + ms

      local call = choice.message and choice.message.tool_calls and choice.message.tool_calls[1]
      if not call then
        return cb("model did not call emit_code")
      end
      local ok, args = pcall(vim.json.decode, call["function"].arguments or "{}")
      if not ok or type(args.code) ~= "string" or args.code == "" then
        return cb("emit_code returned no code")
      end

      local code = vim.trim(args.code)
      local lang = args.language or ft
      args._mode = mode

      local function on_verify(passed, report)
        if passed == false and n < MAX_ATTEMPTS then
          ctx.on_step("verify", ("failed, retrying (%d/%d)"):format(n + 1, MAX_ATTEMPTS))
          return attempt(n + 1, target_path, mode, command, code, report)
        end
        finish(target_path, args, code, lang, format_status(mode, passed, report, n))
      end

      -- LSP/lint need the edit in the real buffer before diagnostics refresh.
      if verify.NEEDS_BUFFER[mode] then
        local applied, message, old_text = M.apply(target_path, args.replaces, code)
        if not applied then
          if n < MAX_ATTEMPTS then
            ctx.on_step("verify", ("apply failed, retrying (%d/%d)"):format(n + 1, MAX_ATTEMPTS))
            return attempt(n + 1, target_path, mode, command, code, message)
          end
          args._apply_failed = message
          return finish(target_path, args, code, lang,
            format_status(mode, false, "could not apply: " .. message, n))
        end
        args._old_text = old_text
        args._apply_message = message

        local bufnr = verify.buf_for(target_path)
        ctx.on_step("verify", mode)
        return verify.run({
          mode = mode, ft = ft, code = code, command = command, bufnr = bufnr,
        }, function(passed, report)
          if passed == false and n < MAX_ATTEMPTS then
            revert(target_path, old_text, code)
          end
          on_verify(passed, report)
        end)
      end

      ctx.on_step("verify", mode)
      verify.run({ mode = mode, ft = ft, code = code, command = command }, on_verify)
    end)
  end

  local function start(target_path, mode, command)
    local target_buf = verify.buf_for(target_path)
    if target_buf and (ft == nil or ft == "") then
      ft = vim.bo[target_buf].filetype or ft
    end
    -- Prefer the destination buffer for scope + LSP; fall back to the visible one.
    local scope_buf = target_buf or buf
    local scope_row = (scope_buf == buf) and row or 0
    ctx.on_step("scope", "resolving symbols")
    context, label = M.context_for(goal, scope_buf, scope_row)
    ctx.on_step("scope", label)
    attempt(1, target_path, mode, command, nil, nil)
  end

  local function ask_verification(target_path)
    local target_buf = verify.buf_for(target_path)
    if target_buf and (ft == nil or ft == "") then
      ft = vim.bo[target_buf].filetype or ft
    end
    local choices = verify.choices(ft, target_buf)
    local status = verify.status_line(ft, target_buf)
    local q = ("How should I verify this? (filetype: %s)\n%s"):format(
      ft ~= "" and ft or "unknown", status)
    ctx.ask(q, choices, function(picked)
      local mode = picked and picked.id or "none"
      if mode == "test" or mode == "visual" then
        local prompt = mode == "test" and "Test command to run?" or "Command that starts it?"
        return ctx.ask(prompt, nil, function(_, answer)
          start(target_path, mode, answer)
        end)
      end
      start(target_path, mode, nil)
    end)
  end

  -- Which file the code lands in is a decision, not an inference.
  if preset.path then
    return ask_verification(preset.path)
  end

  ctx.ask("Which file should this go in?", candidate_files(), function(picked, raw)
    if picked and picked.id ~= "__other__" then
      return ask_verification(picked.id)
    end
    ctx.ask("Path to the file (relative to cwd):", nil, function(_, answer)
      local path = vim.fn.fnamemodify(vim.trim(answer ~= "" and answer or raw), ":p")
      ask_verification(path)
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- Visual-range entry point: :'<,'>AIWrite <goal>
-- The selection is the thing being replaced, so nothing has to be inferred.
-- ---------------------------------------------------------------------------
function M.run_range(srow, erow, goal, ctx, cb)
  local buf = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then
    return cb("this buffer has no file name; save it first")
  end
  local selected = table.concat(vim.api.nvim_buf_get_lines(buf, srow - 1, erow, false), "\n")
  M.run(goal .. "\n\nReplace exactly this selection:\n" .. selected,
    ctx, cb, { path = path, replaces = selected })
end

return M
