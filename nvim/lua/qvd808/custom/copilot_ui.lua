-- Visual layer for the CodeCompanion chat buffer: tinted Copilot replies, code-block backgrounds, bar-style
-- role headers and a toggle for the folded reasoning. Layout (window size) is left to the plugin defaults.
local M = {}

local NS = vim.api.nvim_create_namespace("copilot-ui")
local ROLE_USER, ROLE_LLM = "▌ You", "▌ Copilot"

-- Backgrounds derive from Normal so they follow any colorscheme
local function shade(rgb, delta)
  local function ch(v)
    return math.max(0, math.min(255, math.floor(v + delta)))
  end
  return ch(math.floor(rgb / 65536) % 256) * 65536 + ch(math.floor(rgb / 256) % 256) * 256 + ch(rgb % 256)
end

local function define_highlights()
  local hl = vim.api.nvim_set_hl
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local base = normal.bg or (vim.o.background == "light" and 0xFFFFFF or 0x1A1A1A)
  local r, g, b = math.floor(base / 65536) % 256, math.floor(base / 256) % 256, base % 256
  local dir = (0.299 * r + 0.587 * g + 0.114 * b) < 128 and 1 or -1

  hl(0, "CopilotUiReply", { bg = shade(base, dir * 8) })
  hl(0, "CopilotUiCode", { bg = shade(base, dir * 22) })
  hl(0, "CopilotUiReasoning", { bg = shade(base, dir * 14), italic = true })
  hl(0, "CopilotUiUser", { link = "Function" })
  hl(0, "CopilotUiBot", { link = "Identifier" })
  hl(0, "CodeCompanionChatHeader", { link = "Title" })
  hl(0, "CodeCompanionChatSeparator", { link = "Comment" })
  hl(0, "CodeCompanionChatFold", { link = "Comment", italic = true })
end

-- Classifies each buffer row: reply / reasoning / user / code. Returns row -> kind (0-indexed).
local function classify(lines)
  local kinds, role, reasoning, fenced = {}, nil, false, false
  for i, line in ipairs(lines) do
    local row = i - 1
    local h2 = line:match("^## (.*)")
    if h2 then
      role = h2:find(ROLE_USER, 1, true) and "user" or "reply"
      reasoning, fenced = false, false
      kinds[row] = role == "user" and "user_header" or "reply_header"
    else
      local h3 = line:match("^### (.*)")
      if h3 and not fenced then
        reasoning = h3:match("^Reasoning") ~= nil
      end
      if line:match("^%s*```") then
        fenced = not fenced
        kinds[row] = role == "reply" and "code" or nil
      elseif role == "reply" then
        kinds[row] = fenced and "code" or (reasoning and "reasoning" or "reply")
      end
    end
  end
  return kinds
end

local function attach_provider()
  local cache = {}
  vim.api.nvim_set_decoration_provider(NS, {
    on_win = function(_, _, buf)
      if vim.bo[buf].filetype ~= "codecompanion" then
        return false
      end
      cache[buf] = classify(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    end,
    on_line = function(_, _, buf, row)
      local kind = cache[buf] and cache[buf][row]
      local group = ({
        reply = "CopilotUiReply",
        reasoning = "CopilotUiReasoning",
        code = "CopilotUiCode",
      })[kind]
      if group then
        vim.api.nvim_buf_set_extmark(buf, NS, row, 0, { line_hl_group = group, priority = 90, ephemeral = true })
      elseif kind == "user_header" or kind == "reply_header" then
        vim.api.nvim_buf_set_extmark(buf, NS, row, 0, {
          line_hl_group = kind == "reply_header" and "CopilotUiReply" or nil,
          end_col = #vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1],
          hl_group = kind == "user_header" and "CopilotUiUser" or "CopilotUiBot",
          priority = 200,
          ephemeral = true,
        })
      end
    end,
  })
end

local show_reasoning = true

-- Body rows (0-indexed, inclusive) of every "### Reasoning" block: up to the next heading, minus trailing blanks
local function reasoning_ranges(lines)
  local ranges, start, fenced = {}, nil, false
  local function close(last)
    if start then
      while last >= start and lines[last + 1]:match("^%s*$") do
        last = last - 1
      end
      if last >= start then
        table.insert(ranges, { start, last })
      end
      start = nil
    end
  end
  for i, line in ipairs(lines) do
    if line:match("^%s*```") then
      fenced = not fenced
    elseif not fenced and line:match("^##") then
      close(i - 2)
      if line:match("^### Reasoning") then
        start = i
      end
    end
  end
  close(#lines - 1)
  return ranges
end

-- Folds or unfolds every reasoning block in the chat window, and makes the plugin fold future ones the same way.
-- With reasoning shown the plugin creates no folds, so the folds are made here (the plugin's foldtext labels them).
function M.toggle_reasoning()
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].filetype ~= "codecompanion" then
    return
  end
  show_reasoning = not show_reasoning
  require("codecompanion.config").display.chat.fold_reasoning = not show_reasoning
  local Folds = require("codecompanion.interactions.chat.ui.folds")
  Folds.fold_summaries[buf] = Folds.fold_summaries[buf] or {}
  local summaries = Folds.fold_summaries[buf]
  local view = vim.fn.winsaveview()
  local ranges = reasoning_ranges(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  for _, r in ipairs(ranges) do
    local first, last = r[1] + 1, r[2] + 1
    if vim.fn.foldlevel(first) == 0 then
      vim.cmd(("%d,%dfold"):format(first, last))
      summaries[r[1]] = { type = "reasoning", content = "  " .. M.display.chat.icons.chat_fold .. " ..." }
    end
    pcall(vim.cmd, ("%dfold%s"):format(first, show_reasoning and "open" or "close"))
  end
  vim.fn.winrestview(view)
  vim.notify(
    ("Reasoning: %s (%d block%s)"):format(show_reasoning and "shown" or "folded", #ranges, #ranges == 1 and "" or "s"),
    vim.log.levels.INFO,
    { title = "Copilot" }
  )
end

-- Only the prompt under the last "You" header is editable; earlier turns are read-only, like the old transcript pane.
-- The plugin still unlocks the buffer itself while it writes, and keeps it locked during a request.
local function sync_lock(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_get_current_buf() ~= buf then
    return
  end
  local ok, chat = pcall(function()
    return require("codecompanion").buf_get_chat(buf)
  end)
  if not ok or not chat or chat.current_request then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local prompt_row = 0
  for i = #lines, 1, -1 do
    if lines[i]:find("^## " .. ROLE_USER, 1) then
      prompt_row = i
      break
    end
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local editable = row > prompt_row
  if vim.bo[buf].modifiable ~= editable then
    vim.bo[buf].modifiable = editable
    vim.bo[buf].modified = false
  end
end

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local busy_since = {} -- bufnr -> hrtime when the in-flight request started
local timer
local queued = {} -- bufnr -> prompts typed while a request was running, sent one per finished turn

local function fmt_k(n)
  return n >= 1000 and ("%.1fk"):format(n / 1000) or tostring(n)
end

-- Winbar for a window `width` columns wide. Segments are added in priority order (busy, usage, hints) and dropped
-- when they would not fit, so the spinner and token count stay visible in a narrow split.
local function winbar_for(chat, width)
  width = width or vim.o.columns
  local used = chat and chat.tokens
  local size = chat and chat._ctx_size
  local segs = {}
  local function add(plain, hl)
    table.insert(segs, { plain = plain, hl = hl })
  end

  local b = chat and chat.bufnr and busy_since[chat.bufnr]
  if b then
    local frame = SPINNER[math.floor((vim.uv.hrtime() - b) / 1e8) % #SPINNER + 1]
    add((" %s %3ds"):format(frame, (vim.uv.hrtime() - b) / 1e9), "CopilotUiBot")
  end
  local q = chat and chat.bufnr and queued[chat.bufnr]
  if q and #q > 0 then
    add((" 󰒲 %d queued"):format(#q), "DiagnosticWarn")
  end
  if used and used > 0 then
    if size and size > 0 then
      local pct = used / size * 100
      add(
        (" %s/%s %d%%"):format(fmt_k(used), fmt_k(size), pct),
        pct >= 80 and "DiagnosticError" or pct >= 50 and "DiagnosticWarn" or "DiagnosticOk"
      )
      if pct >= 70 then
        add(" /compact?", "DiagnosticWarn")
      end
    else
      add(" " .. fmt_k(used) .. " tokens", "Comment")
    end
  end

  local name = width >= 24 and " 󰚩 Copilot" or " 󰚩"
  local out, room = "%#CopilotUiBot#" .. name .. "%*", width - vim.fn.strdisplaywidth(name)
  for _, seg in ipairs(segs) do
    local w = vim.fn.strdisplaywidth(seg.plain)
    if w <= room then
      out = out .. ("%%#%s#%s%%*"):format(seg.hl, seg.plain:gsub("%%", "%%%%"))
      room = room - w
    end
  end
  for _, hint in ipairs({ "gq queue  <leader>ch hide reasoning  <leader>cr level  <leader>cm model", "<leader>ch  <leader>cr  <leader>cm" }) do
    if vim.fn.strdisplaywidth(hint) + 2 <= room then
      return out .. "%=%#Comment#" .. hint .. " %*"
    end
  end
  return out
end

local function refresh_winbar(chat)
  if not chat or not chat.bufnr then
    return
  end
  for _, win in ipairs(vim.fn.win_findbuf(chat.bufnr)) do
    vim.wo[win].winbar = winbar_for(chat, vim.api.nvim_win_get_width(win))
  end
end

local function tick()
  if next(busy_since) == nil then
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end
    return
  end
  for buf in pairs(busy_since) do
    local ok, chat = pcall(function()
      return require("codecompanion").buf_get_chat(buf)
    end)
    refresh_winbar(ok and chat or nil)
  end
end

local function set_busy(buf, on)
  if not buf then
    return
  end
  busy_since[buf] = on and vim.uv.hrtime() or nil
  if on and not timer then
    timer = vim.uv.new_timer()
    timer:start(0, 100, vim.schedule_wrap(tick))
  end
  if not on then
    tick()
    local ok, chat = pcall(function()
      return require("codecompanion").buf_get_chat(buf)
    end)
    refresh_winbar(ok and chat or nil)
  end
end

-- Copilot only reports usage after a prompt, not on session/load, so a resumed chat would show nothing until the
-- next reply. Keep the last report per session and restore it on resume.
local USAGE_FILE = vim.fn.stdpath("state") .. "/copilot-usage.json"

local function read_usage()
  local f = io.open(USAGE_FILE)
  if not f then
    return {}
  end
  local ok, data = pcall(vim.json.decode, f:read("*a"))
  f:close()
  return ok and type(data) == "table" and data or {}
end

local function save_usage(sid, used, size)
  local data = read_usage()
  data[sid] = { used = used, size = size }
  local f = io.open(USAGE_FILE, "w")
  if f then
    f:write(vim.json.encode(data))
    f:close()
  end
end

-- Fallback for sessions never seen here (e.g. started in the CLI): the CLI's own log of the last main-agent call.
-- Its input count runs a few percent above what the agent reports over ACP, so it is an estimate.
local function usage_from_events(sid)
  local f = io.open(vim.fn.expand("~/.copilot/session-state/") .. sid .. "/events.jsonl")
  if not f then
    return nil
  end
  local size = f:seek("end")
  f:seek("set", math.max(0, size - 2 * 1024 * 1024))
  local tail = f:read("*a")
  f:close()
  local found
  for line in tail:gmatch("[^\n]+") do
    if line:find('"session.usage_record"', 1, true) and line:find('"conversation-agent"', 1, true) then
      found = line
    end
  end
  local ok, ev = pcall(vim.json.decode, found or "")
  local u = ok and type(ev) == "table" and ev.data and ev.data.usage
  if u and u.inputTokens and u.maxPromptTokens then
    return { used = u.inputTokens + (u.outputTokens or 0), size = u.maxPromptTokens }
  end
end

-- Copilot does not replay its thinking over session/load, but its own event log keeps it per assistant message.
-- Returns one string (or false) per user turn, in order.
local function reasoning_from_events(sid)
  local f = io.open(vim.fn.expand("~/.copilot/session-state/") .. sid .. "/events.jsonl")
  if not f then
    return nil
  end
  local turns = {}
  for line in f:lines() do
    local head = line:sub(1, 40)
    if head:find('"type":"user.message"', 1, true) then
      table.insert(turns, {})
    elseif head:find('"type":"assistant.message"', 1, true) and #turns > 0 and line:find('"reasoningText"', 1, true) then
      local ok, ev = pcall(vim.json.decode, line)
      local text = ok and type(ev) == "table" and ev.data and ev.data.reasoningText
      if type(text) == "string" and text ~= "" then
        table.insert(turns[#turns], text)
      end
    end
  end
  f:close()
  return vim.tbl_map(function(t)
    return #t > 0 and table.concat(t, "\n\n") or false
  end, turns)
end

-- Puts a "### Reasoning" block at the top of each restored Copilot reply, matching what a live reply looks like.
-- Only done when the number of replies matches the number of user turns, so a mismatch can't misplace text.
local function restore_reasoning(buf, sid)
  if not (buf and sid and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local turns = reasoning_from_events(sid)
  if not turns or #turns == 0 then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local replies = {}
  for i, line in ipairs(lines) do
    if line:find("^## " .. ROLE_LLM) then
      table.insert(replies, i)
    end
  end
  if #replies ~= #turns then
    return
  end
  local was = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  for n = #replies, 1, -1 do
    local text = turns[n]
    if text then
      local at = replies[n] + 1
      while lines[at] and lines[at]:match("^%s*$") do
        at = at + 1
      end
      local block = { "### Reasoning", "" }
      vim.list_extend(block, vim.split(text, "\n", { plain = true }))
      vim.list_extend(block, { "", "### Response", "" })
      vim.api.nvim_buf_set_lines(buf, at - 1, at - 1, false, block)
    end
  end
  vim.bo[buf].modified = false
  vim.bo[buf].modifiable = was
end

local function restore_usage(buf, sid)
  local ok, chat = pcall(function()
    return require("codecompanion").buf_get_chat(buf)
  end)
  if not ok or not chat or not sid then
    return
  end
  local u = read_usage()[sid] or usage_from_events(sid)
  if u then
    chat.tokens, chat._ctx_size = u.used, u.size
    refresh_winbar(chat)
  end
end

-- The plugin keeps only `used` from the agent's usage_update; capture the window size too and redraw the winbar
local function hook_usage()
  local Connection = require("codecompanion.acp")
  if Connection._usage_hooked then
    return
  end
  local handle = Connection.handle_incoming_request_or_notification
  Connection.handle_incoming_request_or_notification = function(self, n)
    local res = handle(self, n)
    local u = type(n) == "table" and n.method == "session/update" and n.params and n.params.update
    if u and u.sessionUpdate == "usage_update" then
      local chat = self.chat
      if chat then
        chat._ctx_size = u.size or chat._ctx_size
        vim.schedule(function()
          refresh_winbar(chat)
        end)
      end
      if n.params.sessionId and u.used then
        vim.schedule(function()
          save_usage(n.params.sessionId, u.used, u.size)
        end)
      end
    end
    return res
  end
  Connection._usage_hooked = true
end

local function send_now(chat, text)
  if not require("qvd808.custom.copilot_workflow").can_submit(chat) then
    return false
  end
  local buf = chat.bufnr
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, vim.split(text, "\n", { plain = true }))
  chat:submit()
  return true
end

local function flush_queue(buf)
  local q = queued[buf]
  local ok, chat = pcall(function()
    return require("codecompanion").buf_get_chat(buf)
  end)
  if not q or #q == 0 or not ok or not chat or chat.current_request then
    return
  end
  if not require("qvd808.custom.copilot_workflow").can_submit(chat, true) then
    vim.notify("Queued follow-ups held for work-unit review (<leader>ac)", vim.log.levels.INFO, { title = "Copilot" })
    return
  end
  if send_now(chat, q[1]) then
    table.remove(q, 1)
    refresh_winbar(chat)
  end
end

-- Prompt for a follow-up. Idle: sends it. Busy: queues it and sends it when the current turn finishes.
-- Stopping the request drops the queue.
function M.queue()
  local buf = vim.api.nvim_get_current_buf()
  local ok, chat = pcall(function()
    return require("codecompanion").buf_get_chat(buf)
  end)
  if not ok or not chat then
    return
  end
  vim.ui.input({ prompt = chat.current_request and "Queue follow-up: " or "Send: " }, function(text)
    if not text or not text:match("%S") then
      return
    end
    local allowed = require("qvd808.custom.copilot_workflow").can_submit(chat, true)
    if not chat.current_request and allowed and send_now(chat, text) then
      return
    end
    queued[buf] = queued[buf] or {}
    table.insert(queued[buf], text)
    refresh_winbar(chat)
    if not chat.current_request then
      vim.notify("Follow-up queued; use <leader>ac then r to include it in this outcome", vim.log.levels.INFO, { title = "Copilot" })
    end
  end)
end

function M.queued_followups(chat)
  return vim.deepcopy(queued[chat.bufnr] or {})
end

function M.clear_followups(chat)
  queued[chat.bufnr] = nil
  refresh_winbar(chat)
end

-- Picker for the agent's reasoning-level option (same picker as /acp_session_options, but jumps straight to it)
function M.reasoning()
  local cc = require("codecompanion")
  local chat = cc.buf_get_chat(vim.api.nvim_get_current_buf()) or cc.last_chat()
  local conn = chat and chat.acp_connection
  if not conn then
    return vim.notify("Open a Copilot chat and send a message first", vim.log.levels.WARN, { title = "Copilot" })
  end
  local opts = conn:get_config_options()
  local found
  for _, o in ipairs(opts) do
    local hay = ((o.category or "") .. " " .. (o.id or "") .. " " .. (o.name or "")):lower()
    if o.category ~= "model" and (hay:find("reason") or hay:find("thought") or hay:find("effort")) then
      found = o
      break
    end
  end
  if not found then
    local names = vim.tbl_map(function(o)
      return o.name or o.id
    end, opts)
    return vim.notify(
      "Agent exposes no reasoning option. Options: " .. table.concat(names, ", "),
      vim.log.levels.WARN,
      { title = "Copilot" }
    )
  end
  local cmd = require("codecompanion.interactions.chat.slash_commands.builtin.acp_session_options")
  cmd.new({ Chat = chat }):show_values(found)
end

function M.help()
  require("codecompanion.interactions.chat.keymaps").options.callback()
  local buf = vim.api.nvim_get_current_buf()
  local lines = {
    "### Copilot shortcuts (Normal mode)",
    "",
    " <leader>ac  Open workflow graph",
    " <leader>cc  Toggle chat     <leader>cl  List open chats",
    " <leader>ca  Actions         <leader>cf  Changed files",
    " <leader>cm  Model picker    <leader>cr  Reasoning level",
    " <leader>ch  Toggle reasoning visibility",
    " gq          Send / queue follow-up",
    "",
    "### Workflow controls (inside <leader>ac)",
    "",
    " N      New ticket / reviewable outcome (starts immediately)",
    " o      Open workflow chat",
    " d      Answer clarification     c  Resume interrupted work",
    " a      Accept outcome           r  Request revisions",
    " n      Next outcome after acceptance",
    " L      Load saved workflow      <CR>  Selected node details",
    "",
    " One request = one reviewable outcome, not one gate per file.",
    " Queued follow-ups wait at review; use r to include them.",
    " The write-approval dialog remains separate.",
    "",
    " q      Close this help",
    "",
  }
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, lines)
  vim.bo[buf].modified = false
  vim.bo[buf].modifiable = false
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
end

local function style_window(win)
  for k, v in pairs({
    number = false,
    relativenumber = false,
    signcolumn = "no",
    cursorline = false,
    list = false,
    conceallevel = 0,
    foldcolumn = "0",
    breakindent = false,
  }) do
    vim.wo[win][k] = v
  end
  local ok, chat = pcall(function()
    return require("codecompanion").buf_get_chat(vim.api.nvim_win_get_buf(win))
  end)
  vim.wo[win].winbar = winbar_for(ok and chat or nil, vim.api.nvim_win_get_width(win))
end

-- Values merged into the plugin's `opts`
M.display = {
  chat = {
    intro_message = "Press ? for options",
    show_header_separator = true,
    separator = "─",
    show_reasoning = true,
    fold_reasoning = false,
    icons = { chat_fold = " " },
  },
}

M.roles = {
  user = ROLE_USER,
  llm = function()
    return ROLE_LLM
  end,
}

function M.setup()
  define_highlights()
  attach_provider()
  hook_usage()
  local group = vim.api.nvim_create_augroup("copilot-ui", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeCompanionRequestStarted",
    callback = function(a)
      set_busy(a.data and a.data.bufnr, true)
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeCompanionRequestFinished",
    callback = function(a)
      set_busy(a.data and a.data.bufnr, false)
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeCompanionChatDone",
    callback = function(a)
      local buf = a.data and a.data.bufnr
      vim.schedule(function()
        flush_queue(buf)
      end)
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeCompanionChatStopped",
    callback = function(a)
      local buf = a.data and a.data.bufnr
      if buf and queued[buf] and #queued[buf] > 0 then
        queued[buf] = nil
        vim.notify("Queued follow-ups dropped", vim.log.levels.INFO, { title = "Copilot" })
      end
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeCompanionACPChatRestored",
    callback = function(a)
      local d = a.data or {}
      restore_usage(d.bufnr, d.session_id)
      vim.schedule(function()
        restore_reasoning(d.bufnr, d.session_id)
      end)
    end,
  })
  vim.api.nvim_create_autocmd("WinResized", {
    group = group,
    callback = function()
      for _, win in ipairs(vim.v.event.windows or {}) do
        local buf = vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win)
        if buf and vim.bo[buf].filetype == "codecompanion" then
          local ok, chat = pcall(function()
            return require("codecompanion").buf_get_chat(buf)
          end)
          vim.wo[win].winbar = winbar_for(ok and chat or nil, vim.api.nvim_win_get_width(win))
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = define_highlights })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "codecompanion",
    callback = function(args)
      vim.keymap.set("n", "<leader>ch", M.toggle_reasoning, { buffer = args.buf, desc = "Toggle Copilot reasoning" })
      vim.keymap.set("n", "gq", M.queue, { buffer = args.buf, desc = "Queue follow-up while Copilot works" })
      vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "InsertEnter", "BufEnter" }, {
        group = group,
        buffer = args.buf,
        callback = function()
          sync_lock(args.buf)
        end,
      })
      vim.schedule(function()
        for _, win in ipairs(vim.fn.win_findbuf(args.buf)) do
          style_window(win)
        end
      end)
    end,
  })
end

return M
