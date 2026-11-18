-- Left-to-right state diagram of a work-unit workflow, in the spirit of an FSM drawing: a chain of unit boxes, and
-- under it the selected unit's states (working -> review -> done) with a "decline" edge back to working. Each state
-- box is filled with its colour. At a gate the same window pops up with a banner; a accepts, d declines.
local M = {}
local api = vim.api
local namespace = api.nvim_create_namespace("copilot_workflow_view")
local view = {}

local MAX_WIDTH = 104
local UNIT_W, STATE_W, ARROW = 18, 16, " ─▶ "

local function clean(value)
  local cleaned = tostring(value or ""):gsub("\t", "    "):gsub("[%z\1-\8\11-\31\127]", "?")
  return cleaned
end

local function dw(value)
  return vim.fn.strdisplaywidth(value)
end

local function wrap(value, width)
  local result = {}
  for paragraph in (clean(value) .. "\n"):gmatch("(.-)\n") do
    local line = ""
    for _, char in ipairs(vim.fn.split(paragraph, "\\zs")) do
      if dw(line .. char) > width then
        if line ~= "" then
          result[#result + 1] = line
        end
        line = dw(char) <= width and char or "?"
      else
        line = line .. char
      end
    end
    result[#result + 1] = line
  end
  return result
end

local function fit(value, width)
  value = clean(value)
  if dw(value) <= width then
    return value
  end
  local out = ""
  for _, char in ipairs(vim.fn.split(value, "\\zs")) do
    if dw(out .. char) > width - 1 then
      break
    end
    out = out .. char
  end
  return out .. "…"
end

local function pad(value, width, fill)
  return value .. string.rep(fill or " ", math.max(0, width - dw(value)))
end

local function center(value, width)
  local left = math.max(0, math.floor((width - dw(value)) / 2))
  return pad(string.rep(" ", left) .. value, width)
end

-- status -> { colour group suffix, icon }
local STATUS = {
  planning = { "Plan", "✎" },
  awaiting_plan = { "Review", "◆" },
  running = { "Running", "●" },
  awaiting_review = { "Review", "◆" },
  needs_decision = { "Decision", "?" },
  paused = { "Paused", "‖" },
  accepted = { "Done", "✔" },
  done = { "Done", "✔" },
  completed = { "Done", "✔" },
  pending = { "Pending", "○" },
  failed = { "Decision", "✘" },
  cancelled = { "Paused", "✘" },
  blocked = { "Paused", "‖" },
}

local function status_of(status)
  return STATUS[status] or STATUS.pending
end

local function group_for(status)
  return "CopilotWf" .. status_of(status)[1]
end

local function define_highlights()
  local normal = api.nvim_get_hl(0, { name = "Normal", link = false })
  local base = normal.bg or (vim.o.background == "light" and 0xFFFFFF or 0x1A1A1A)
  local function mix(a, b, t)
    local function ch(shift)
      local x, y = math.floor(a / shift) % 256, math.floor(b / shift) % 256
      return math.floor(x + (y - x) * t)
    end
    return ch(65536) * 65536 + ch(256) * 256 + ch(1)
  end
  for suffix, source in pairs({
    Plan = "Special",
    Running = "DiagnosticInfo",
    Review = "DiagnosticWarn",
    Decision = "DiagnosticError",
    Paused = "DiagnosticHint",
    Done = "DiagnosticOk",
    Pending = "Comment",
  }) do
    local color = api.nvim_get_hl(0, { name = source, link = false }).fg or 0x888888
    api.nvim_set_hl(0, "CopilotWf" .. suffix, { fg = color, bg = mix(base, color, 0.14) })
    api.nvim_set_hl(0, "CopilotWf" .. suffix .. "Gate", { fg = color, bg = mix(base, color, 0.3), bold = true })
  end
end

local function counts(unit)
  local done, total = 0, 0
  for _, todo in ipairs(unit.todos or {}) do
    total = total + 1
    if todo.status == "done" then
      done = done + 1
    end
  end
  return done, total
end

local function progress(done, total, width)
  if total == 0 then
    return string.rep("▱", width)
  end
  local filled = math.floor(done / total * width + 0.5)
  return string.rep("▰", filled) .. string.rep("▱", width - filled) .. (" %d/%d"):format(done, total)
end

-- Rows of a unit's detail section
local function details(unit)
  local rows = {}
  local function add(value)
    rows[#rows + 1] = value
  end
  if unit.problem and unit.problem ~= "" then
    add("Problem: " .. clean(unit.problem))
  end
  if unit.summary and unit.summary ~= "" then
    add("Summary: " .. clean(unit.summary))
  end
  if unit.decision and unit.decision ~= "" then
    add("Question: " .. clean(unit.decision))
  end
  local by_id = {}
  for _, todo in ipairs(unit.todos or {}) do
    by_id[todo.id] = todo
  end
  if #(unit.todos or {}) > 0 then
    add("")
    add("Todos")
    for _, todo in ipairs(unit.todos) do
      local marker = ({ done = "✔", running = "▶", pending = "○" })[todo.status] or "?"
      local line = ("  %s %s %s"):format(marker, clean(todo.id), clean(todo.title))
      local waiting = {}
      for _, id in ipairs(todo.depends_on or {}) do
        if not by_id[id] or by_id[id].status ~= "done" then
          waiting[#waiting + 1] = clean(id)
        end
      end
      if #waiting > 0 then
        line = line .. "  ⧖ " .. table.concat(waiting, ",")
      end
      add(line)
      if todo.evidence and todo.evidence ~= "" then
        add("      ↳ " .. clean(todo.evidence))
      end
    end
  end
  if #(unit.jobs or {}) > 0 then
    add("")
    add("Agents")
    for _, job in ipairs(unit.jobs) do
      local status = clean(job.status)
      if job.status == "completed" then
        status = job.collected and "done" or "finished, not collected"
      end
      add(("  ⚙ %s %s [%s]"):format(clean(job.id), clean(job.name), status))
    end
  end
  local checks = {}
  for _, command in ipairs(unit.required_checks or {}) do
    local observed
    for _, check in ipairs(unit.checks or {}) do
      if check.command == command then
        observed = check
      end
    end
    local mark = not observed and "○" or observed.exit_code == 0 and "✔" or observed.exit_code == nil and "…" or "✘"
    checks[#checks + 1] = ("  %s %s"):format(mark, clean(command))
  end
  if #checks > 0 then
    add("")
    add("Required checks")
    vim.list_extend(rows, checks)
  end
  if #(unit.plan_commands or {}) > 0 then
    add("")
    add("Pre-approved commands")
    for _, command in ipairs(unit.plan_commands) do
      add("  " .. clean(command))
    end
  end
  if #(unit.artifacts or {}) > 0 then
    add("")
    add("Artifacts")
    for _, artifact in ipairs(unit.artifacts) do
      add("  " .. clean(artifact))
    end
  end
  return rows
end

local STAGES = {
  { "planning", "Planning" }, { "awaiting_plan", "Approve plan" },
  { "running", "Working" }, { "awaiting_review", "Review" },
  { "accepted", "Accepted" },
}

function M.render(state, width, selected_unit_id)
  width = math.max(1, math.floor(tonumber(width) or 80))
  local lines, highlights = {}, {}
  -- A line is a list of { text, group? } segments; groups colour just that segment (byte offsets)
  local function line(segments, whole_group)
    local text = ""
    for _, segment in ipairs(segments) do
      if segment[2] then
        highlights[#highlights + 1] = { line = #lines, start_col = #text, end_col = #text + #segment[1], group = segment[2] }
      end
      text = text .. segment[1]
    end
    lines[#lines + 1] = text
    if whole_group then
      highlights[#highlights + 1] = { line = #lines - 1, group = whole_group }
    end
  end
  local function text(value, group)
    for _, row in ipairs(wrap(value, width)) do
      line({ { row } }, group)
    end
  end
  -- Boxes of equal height laid out left to right: boxes = { rows = {string...}, group }, arrows on the 2nd row
  local function hrow(boxes, gap)
    if #boxes == 0 then return end
    local height = #boxes[1].rows
    for r = 1, height do
      local segments = {}
      for index, box in ipairs(boxes) do
        segments[#segments + 1] = { box.rows[r], box.group }
        if index < #boxes then
          segments[#segments + 1] = { r == 2 and gap or string.rep(" ", dw(gap)), "Comment" }
        end
      end
      line(segments)
    end
  end
  local function banner(title, body, group)
    if width < 8 then
      text(title, group)
      for _, row in ipairs(body) do text(row, group) end
      return
    end
    title = fit(title, width - 5)
    local inner = width - 4
    line({ { "╭─ " .. title .. " " .. string.rep("─", math.max(0, width - 5 - dw(title))) .. "╮" } }, group)
    for _, row in ipairs(body) do
      for _, wrapped in ipairs(wrap(row, inner)) do
        line({ { "│ " .. pad(wrapped, inner) .. " │" } }, group)
      end
    end
    line({ { "╰" .. string.rep("─", width - 2) .. "╯" } }, group)
  end

  text("Copilot workflow", "Title")
  if not state then
    text("")
    text("No workflow loaded.", "DiagnosticInfo")
    text("")
    text("N  new ticket     L  load a saved one", "Comment")
    text("q  close", "Comment")
    return lines, highlights
  end

  text(fit(state.goal, width * 2), "Comment")
  local units = state.units or {}
  local current_index = (tonumber(state.active) or -1) + 1
  local current = units[current_index]

  if current and current.status == "awaiting_plan" then
    text("")
    local body = { current.problem ~= "" and clean(current.problem) or "(no problem recorded)", "" }
    for _, todo in ipairs(current.todos or {}) do
      body[#body + 1] = ("○ %s %s"):format(clean(todo.id), clean(todo.title))
    end
    body[#body + 1] = ""
    body[#body + 1] = "[a] approve: it then runs on its own     [d] decline, discuss in chat"
    banner("GATE · approve this plan?", body, "CopilotWfReviewGate")
  elseif current and current.status == "awaiting_review" then
    text("")
    banner("GATE · move to the next state?", {
      current.summary ~= "" and clean(current.summary) or "(no summary)",
      "",
      "[a] accept        [d] decline, then talk it through in chat",
    }, "CopilotWfReviewGate")
  elseif current and current.status == "needs_decision" then
    text("")
    banner("GATE · the agent has a question", {
      current.decision ~= "" and clean(current.decision) or "(see chat)",
      "",
      "[d] reply in chat",
    }, "CopilotWfDecisionGate")
  end

  -- Units, left to right (the newest ones when they do not all fit)
  local shown = math.max(1, math.floor((width + dw(ARROW)) / (UNIT_W + dw(ARROW))))
  local first = math.max(1, #units - shown + 1)
  local focus = selected_unit_id and (function()
    for _, unit in ipairs(units) do
      if unit.id == selected_unit_id then
        return unit
      end
    end
  end)() or current
  local focus_index = current_index
  for index, unit in ipairs(units) do
    if unit == focus then focus_index = index end
  end
  first = math.max(1, math.min(first, focus_index))
  local last = math.min(#units, first + shown - 1)
  text("")
  text("Tickets · Enter cycles selection", "Title")
  local boxes = {}
  for index = first, last do
    local unit = units[index]
    local mark = unit == focus and "▸" or " "
    local label = ("%s%s %s "):format(mark, clean(unit.id), status_of(unit.status)[2])
    local done, total = counts(unit)
    boxes[#boxes + 1] = {
      group = group_for(unit.status),
      rows = {
        "╭" .. pad(label, UNIT_W - 2, "─") .. "╮",
        "│ " .. pad(fit(unit.title, UNIT_W - 4), UNIT_W - 4) .. " │",
        "│ " .. pad(progress(done, total, 6), UNIT_W - 4) .. " │",
        "╰" .. string.rep("─", UNIT_W - 2) .. "╯",
      },
    }
  end
  if first > 1 then
    text(("… %d earlier unit%s"):format(first - 1, first > 2 and "s" or ""), "Comment")
  end
  if width >= UNIT_W then
    hrow(boxes, ARROW)
  elseif focus then
    text(focus.id .. " · " .. focus.title, group_for(focus.status))
  end
  if last < #units then text(("… %d later units"):format(#units - last), "Comment") end

  if not focus then
    text("")
    text("No current unit. N new ticket / l load", "Comment")
    return lines, highlights
  end

  text("")
  text(("Ticket %s · %s"):format(clean(focus.id), clean(focus.title)), "Title")
  local done, total = counts(focus)
  text(("Status: %s · Attempt %d · Tasks %d/%d"):format(
    clean(focus.status), focus.attempt or 1, done, total), group_for(focus.status))
  if focus ~= current then text("Older unit · read-only", "DiagnosticWarn") end
  text("")
  text("Workflow · " .. clean(focus.status), "Title")
  local stage_boxes = {}
  local horizontal = width >= #STAGES * STATE_W + (#STAGES - 1) * dw(ARROW)
  local box_width = horizontal and STATE_W or math.min(22, width)
  for _, stage in ipairs(STAGES) do
    local active = focus.status == stage[1]
    local group = active and (group_for(focus.status) .. "Gate") or "CopilotWfPending"
    local label = stage[2]
    if box_width >= 8 then
      stage_boxes[#stage_boxes + 1] = {
        group = group,
        rows = {
          "╭" .. string.rep("─", box_width - 2) .. "╮",
          "│" .. center(fit(label, box_width - 2), box_width - 2) .. "│",
          "╰" .. string.rep("─", box_width - 2) .. "╯",
        },
      }
    else
      text(label, group)
    end
  end
  if horizontal then
    hrow(stage_boxes, ARROW)
    local left = math.floor(STATE_W / 2)
    local right = (STATE_W + dw(ARROW)) * 3 + left
    text(string.rep(" ", left) .. "▲" .. string.rep(" ", right - left - 1) .. "│", "Comment")
    text(string.rep(" ", left) .. "╰" .. pad("─ decline to planning ", right - left - 1, "─") .. "╯", "Comment")
  else
    local edges = { "propose", "approve", "ready", "accept" }
    for index, box in ipairs(stage_boxes) do
      hrow({ box }, "")
      if index < #stage_boxes then text("  │ " .. edges[index] .. "\n  ▼", "Comment") end
    end
    text("Decline: approval/review → Planning", "Comment")
  end
  local decision_group = focus.status == "needs_decision" and "CopilotWfDecisionGate" or "Comment"
  local return_to = focus.approved_attempt == focus.attempt and "Working" or "Planning"
  text("Question → Decision → answer → " .. return_to, decision_group)
  text("Working → Paused → resume → Working",
    focus.status == "paused" and "CopilotWfPausedGate" or "Comment")

  local rows = details(focus)
  if #rows > 0 then
    text("")
    for _, row in ipairs(rows) do
      text(row, (row == "Todos" or row == "Agents" or row == "Required checks" or row == "Artifacts" or row == "Pre-approved commands") and "Title" or nil)
    end
  end

  text("")
  local keys = {
    awaiting_plan = "a approve plan · d decline",
    planning = "chat with the agent; it proposes a plan when you agree",
    awaiting_review = "a accept · d decline",
    needs_decision = "d reply in chat",
    paused = "c resume",
    running = "c resume · o chat",
    accepted = "n next unit",
  }
  text(keys[current and current.status] or "", "Title")
  text("N new ticket · L list · o chat · ⏎ select unit · q close", "Comment")
  return lines, highlights
end

local function notify(message, level)
  vim.notify("Copilot workflow: " .. tostring(message), level or vim.log.levels.ERROR)
end

local function stop_timer()
  if view.timer then
    view.timer:stop()
    view.timer:close()
    view.timer = nil
  end
end

local function cleanup()
  stop_timer()
  local win, buf, group = view.win, view.buf, view.group
  view = {}
  if group then
    api.nvim_del_augroup_by_id(group)
  end
  if win and api.nvim_win_is_valid(win) then
    api.nvim_win_close(win, true)
  end
  if buf and api.nvim_buf_is_valid(buf) then
    api.nvim_buf_delete(buf, { force = true })
  end
end

local function dimensions(line_count)
  local columns = math.max(1, vim.o.columns)
  local rows = math.max(1, vim.o.lines - vim.o.cmdheight)
  local border = columns >= 5 and rows >= 5
  local padding = border and 2 or 0
  local width = math.max(1, math.min(MAX_WIDTH, columns - padding))
  local height = math.max(1, math.min(line_count or rows, rows - padding))
  return {
    relative = "editor",
    width = width,
    height = height,
    col = math.max(0, math.floor((columns - width - padding) / 2)),
    row = math.max(0, math.floor((rows - height - padding) / 2)),
    style = "minimal",
    border = border and "rounded" or "none",
  }
end

function M.is_open()
  return view.win ~= nil and api.nvim_win_is_valid(view.win)
end

function M.refresh()
  if not M.is_open() or not api.nvim_buf_is_valid(view.buf) then
    if view.timer or view.buf then
      cleanup()
    end
    return
  end
  local ok, state = pcall(view.get_state)
  if not ok then
    if state ~= view.last_error then
      notify(state)
      view.last_error = state
    end
    return
  end
  view.last_error = nil
  local workflow_id = state and state.id
  if workflow_id ~= view.workflow_id then
    view.selected_id = nil
    view.workflow_id = workflow_id
  end
  view.units = state and state.units or {}
  local active = state and view.units[(tonumber(state.active) or -1) + 1]
  view.active_id = active and active.id
  local config = dimensions()
  local lines, highlights = M.render(state, config.width, view.selected_id)
  local graphics = require("qvd808.custom.terminal_graphics")
  if graphics.ready() then
    vim.list_extend(lines, graphics.diagram(state, view.selected_id))
  end
  config = dimensions(#lines)
  api.nvim_win_set_config(view.win, config)
  local old_lines = api.nvim_buf_get_lines(view.buf, 0, -1, false)
  if vim.deep_equal(old_lines, lines) and view.drawn_selection == view.selected_id then
    return
  end
  view.drawn_selection = view.selected_id
  local saved_view = api.nvim_win_call(view.win, vim.fn.winsaveview)
  vim.bo[view.buf].modifiable = true
  api.nvim_buf_set_lines(view.buf, 0, -1, false, lines)
  api.nvim_buf_clear_namespace(view.buf, namespace, 0, -1)
  for _, highlight in ipairs(highlights) do
    if highlight.start_col then
      api.nvim_buf_set_extmark(view.buf, namespace, highlight.line, highlight.start_col, {
        end_col = highlight.end_col,
        hl_group = highlight.group,
      })
    else
      api.nvim_buf_set_extmark(view.buf, namespace, highlight.line, 0, { line_hl_group = highlight.group })
    end
  end
  vim.bo[view.buf].modifiable = false
  graphics.attach(view.buf)
  saved_view.lnum = math.min(saved_view.lnum or 1, #lines)
  api.nvim_win_call(view.win, function()
    vim.fn.winrestview(saved_view)
  end)
end

function M.toggle(get_state, actions)
  if M.is_open() then
    cleanup()
    return
  end
  cleanup()
  if type(get_state) ~= "function" then
    notify("get_state must be a function")
    return
  end
  define_highlights()
  view.get_state = get_state
  view.buf = api.nvim_create_buf(false, true)
  vim.bo[view.buf].filetype = "copilot_workflow"
  vim.bo[view.buf].bufhidden = "wipe"
  vim.bo[view.buf].swapfile = false
  vim.bo[view.buf].modifiable = false
  view.win = api.nvim_open_win(view.buf, true, dimensions())
  vim.wo[view.win].wrap = false
  vim.wo[view.win].cursorline = false
  vim.wo[view.win].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder"
  actions = actions or {}
  local bindings =
    { N = "start", n = "next", a = "accept", r = "revise", d = "answer", c = "resume", L = "list", o = "chat" }
  local opens_chat = { start = true, next = true, revise = true, answer = true, resume = true, chat = true }
  local current_only = { next = true, accept = true, revise = true, answer = true, resume = true }
  for key, name in pairs(bindings) do
    local action_name = name
    vim.keymap.set("n", key, function()
      if current_only[action_name] then
        M.refresh()
        if view.last_error then
          notify("Cannot verify the current unit; action cancelled.", vim.log.levels.WARN)
          return
        end
        if view.selected_id and view.selected_id ~= view.active_id then
          notify("Viewing an older unit (read-only). Press Enter to cycle back to the current one.", vim.log.levels.WARN)
          return
        end
      end
      if type(actions[action_name]) ~= "function" then
        notify("action unavailable: " .. action_name)
        return
      end
      if opens_chat[action_name] then
        cleanup()
      end
      local ok, result = pcall(actions[action_name])
      if not ok then
        notify(result)
      elseif result == "close" then
        cleanup()
        return
      end
      M.refresh()
    end, { buffer = view.buf, silent = true, nowait = true, desc = "Workflow " .. action_name })
  end
  -- Cycle which unit's state machine is shown; wrapping back lands on the current unit
  vim.keymap.set("n", "<CR>", function()
    local units = view.units or {}
    local shown = view.selected_id or view.active_id
    local index = 1
    for i, unit in ipairs(units) do
      if unit.id == shown then
        index = i
      end
    end
    local nxt = units[index % math.max(1, #units) + 1]
    view.selected_id = nxt and nxt.id ~= view.active_id and nxt.id or nil
    M.refresh()
  end, { buffer = view.buf, silent = true, nowait = true, desc = "Workflow show next unit" })
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, cleanup, { buffer = view.buf, silent = true, nowait = true })
  end
  view.group = api.nvim_create_augroup("CopilotWorkflowView", { clear = true })
  api.nvim_create_autocmd("WinClosed", {
    group = view.group,
    pattern = tostring(view.win),
    callback = cleanup,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = view.group,
    buffer = view.buf,
    callback = cleanup,
  })
  api.nvim_create_autocmd({ "VimResized", "ColorScheme" }, {
    group = view.group,
    callback = function()
      define_highlights()
      M.refresh()
    end,
  })
  M.refresh()
  local timer = vim.uv.new_timer()
  view.timer = timer
  timer:start(
    750,
    750,
    vim.schedule_wrap(function()
      if view.timer == timer then
        M.refresh()
      end
    end)
  )
end

return M
