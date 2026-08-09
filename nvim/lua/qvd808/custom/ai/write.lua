-- Write workflow: one call, buffer-scoped, no project survey.
--
-- The counterpart to /plan. /plan is for changes whose blast radius you do not
-- yet know, so it pays to survey first. /write is for changes you have already
-- scoped yourself -- "this function, this file" -- where surveying the project
-- would add tokens and no information.
--
-- Context is narrowed as tightly as the editor can manage:
--
--   LSP document symbol   (not wired yet -- see M.scope)
--     -> treesitter enclosing node
--       -> whole buffer
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

You are given a goal and the smallest slice of the buffer that contains it --
often a single function. That slice is the whole job. Do not plan a project, do
not propose files you were not asked about, do not restructure code you cannot
see.

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

  -- rung 1: LSP document symbols. Not wired yet; when it is, it goes here and
  -- falls through to treesitter exactly as treesitter falls through to whole.

  -- rung 2: treesitter
  local sr, er, kind = treesitter_scope(buf, row)
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

function M.run(goal, ctx, cb, preset)
  local verify = require("qvd808.custom.ai.verify")
  preset = preset or {}

  local buf, win = M.target()
  local ft = buf and vim.bo[buf].filetype or ""
  local row = 0
  if win and vim.api.nvim_win_is_valid(win) then
    row = vim.api.nvim_win_get_cursor(win)[1] - 1
  end

  local context, label = M.scope(buf, row)

  local totals = { calls = 0, in_tokens = 0, out_tokens = 0, ms = 0 }

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

      ctx.on_step("verify", mode)
      verify.run({ mode = mode, ft = ft, code = code, command = command },
        function(passed, report)
          if passed == false and n < MAX_ATTEMPTS then
            ctx.on_step("verify", ("failed, retrying (%d/%d)"):format(n + 1, MAX_ATTEMPTS))
            return attempt(n + 1, target_path, mode, command, code, report)
          end

          local status
          if passed == true then
            -- `run` and `build` only prove it did not crash. Show the output so
            -- the reader can judge correctness -- exit 0 on wrong output is
            -- still a pass here, and pretending otherwise would be worse.
            status = "verified: " .. mode
            if report and report ~= "" and report ~= "ok" then
              status = status .. "\n\n```\n" .. report .. "\n```"
              if mode ~= "test" then
                status = status .. "\n_exit code only -- check the output is actually right_"
              end
            end
          elseif passed == false then
            status = ("FAILED after %d attempts (%s)\n\n```\n%s\n```"):format(n, mode, report)
          else
            status = report -- not decidable here: visual / none / no toolchain
          end

          -- Apply through the buffer, then show both complete states.
          local applied, message, old_text = M.apply(target_path, args.replaces, code)
          local D = require("qvd808.custom.ai.diff")

          local text
          if applied then
            text = D.render(old_text, code) .. "\n\n" .. message .. "  _(u to undo)_\n\n"
          else
            text = ("could not apply: %s\n\n```%s\n%s\n```\n\n"):format(message, lang, code)
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
        end)
    end)
  end

  -- Verification strategy is the user's decision: only they know whether
  -- "correct" means it compiles, runs, passes a suite, or looks right.
  ctx.on_step("scope", label)

  local function ask_verification(target_path)
    local choices = verify.choices(ft)
    ctx.ask(("How should I verify this? (filetype: %s)"):format(ft ~= "" and ft or "unknown"),
      choices, function(picked)
        local mode = picked and picked.id or "none"
        if mode == "test" or mode == "visual" then
          local q = mode == "test" and "Test command to run?" or "Command that starts it?"
          return ctx.ask(q, nil, function(_, answer)
            attempt(1, target_path, mode, answer, nil, nil)
          end)
        end
        attempt(1, target_path, mode, nil, nil, nil)
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
