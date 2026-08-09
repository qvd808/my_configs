local M = {}

-- ---------------------------------------------------------------------------
-- Hardcoded provider. Both providers in ~/.pi/agent/models.json speak the
-- openai-completions shape, so swapping is a three-line change for now. A real
-- auth/provider layer comes once we know the UI holds up.
-- ---------------------------------------------------------------------------
local PROVIDER    = "deepseek"
local BASE_URL    = "https://api.deepseek.com"
local MODEL       = "deepseek-chat"
local MODEL_LABEL = "DeepSeek V3"
local AUTH_PATH   = "~/.pi/agent/auth.json"
-- deepseek-chat allows 8192; 2048 silently cut replies off mid-sentence
local MAX_TOKENS  = 8192

local WIDTH_RATIO  = 0.25
local INPUT_HEIGHT = 5
local SPINNER      = { "|", "/", "-", "\\" }

-- Extmark priorities. Treesitter paints at 100, so block backgrounds sit below
-- it (its foreground colours win) and role headers sit above it.
local PRIO_BLOCK  = 90
local PRIO_CODE   = 95
local PRIO_HEADER = 200

-- The spinner lives in its own namespace. Sharing NS and picking a fixed id
-- collides with the ids Neovim auto-assigns to content marks, which start at 1.
local SPIN_MARK = 1

-- Treesitter re-parse cost grows linearly with buffer size (~11 ms at 120
-- lines, ~41 ms at 2400). Cap the scrollback so a long session cannot drift
-- past one frame per edit.
local MAX_LINES = 1200

-- Conversation history budget, in characters (~4 chars per token). Each turn
-- re-sends everything before it, but DeepSeek prefix-caches the shared head --
-- measured 75-97% cache hits across a multi-step run -- so the cost of history
-- is far below its token count. The context window is the real limit, not the
-- bill, which is what this budget protects.
local HISTORY_MAX_CHARS = 96 * 1024

local NS = vim.api.nvim_create_namespace("ai-companion")
local NS_SPIN = vim.api.nvim_create_namespace("ai-companion-spinner")

local state = {
  transcript = { buf = -1, win = -1 },
  input      = { buf = -1, win = -1 },
  job        = nil,
  timer      = nil,
  spin       = 1,
  started    = 0,
  pending_at = nil, -- 0-indexed line the in-flight placeholder starts on
  history    = {},  -- conversation sent to the model, oldest first
  awaiting   = nil, -- workflow waiting for its argument
}

-- Drops whole turns off the front until the history fits the budget. Turns are
-- dropped in pairs so the transcript never starts on an assistant reply to a
-- question the model can no longer see.
local function trim_history()
  local function size()
    local n = 0
    for _, m in ipairs(state.history) do
      n = n + #(m.content or "")
    end
    return n
  end
  while size() > HISTORY_MAX_CHARS and #state.history > 2 do
    table.remove(state.history, 1)
    if state.history[1] and state.history[1].role == "assistant" then
      table.remove(state.history, 1)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Theme. Backgrounds are derived from Normal so they track any colorscheme
-- instead of hardcoding a grey that only works on one.
-- ---------------------------------------------------------------------------
local function shade(rgb, delta)
  local r = math.floor(rgb / 65536) % 256
  local g = math.floor(rgb / 256) % 256
  local b = rgb % 256
  local function clamp(v)
    return math.max(0, math.min(255, math.floor(v + delta)))
  end
  return clamp(r) * 65536 + clamp(g) * 256 + clamp(b)
end

-- alpha 0 = all base, 1 = all target
local function blend(base, target, alpha)
  local function ch(v, shift)
    return math.floor(v / shift) % 256
  end
  local function mix(a, b)
    return math.floor(a + (b - a) * alpha + 0.5)
  end
  return mix(ch(base, 65536), ch(target, 65536)) * 65536
    + mix(ch(base, 256), ch(target, 256)) * 256
    + mix(ch(base, 1), ch(target, 1))
end

local function define_highlights()
  local hl = vim.api.nvim_set_hl
  hl(0, "AIChatUser", { link = "Function",   default = true })
  hl(0, "AIChatBot",  { link = "Identifier", default = true })
  hl(0, "AIChatMeta", { link = "Comment",    default = true })
  hl(0, "AIChatErr",  { link = "ErrorMsg",   default = true })
  hl(0, "AIChatBar",  { link = "StatusLine", default = true })

  -- Both shades come off one base so they can never collide. Borrowing two
  -- different scheme groups looks tempting but many schemes give CursorLine and
  -- ColorColumn the same colour, which erases the code/prose distinction.
  local base
  for _, name in ipairs({ "Normal", "CursorLine", "ColorColumn", "StatusLine" }) do
    local h = vim.api.nvim_get_hl(0, { name = name, link = false })
    if h and h.bg then
      base = h.bg
      break
    end
  end
  base = base or (vim.o.background == "light" and 0xFFFFFF or 0x1A1A1A)

  local r = math.floor(base / 65536) % 256
  local g = math.floor(base / 256) % 256
  local b = base % 256
  -- lighten on a dark scheme, darken on a light one
  local dir = (0.299 * r + 0.587 * g + 0.114 * b) < 128 and 1 or -1
  hl(0, "AIChatAssistant", { bg = shade(base, dir * 10) })
  hl(0, "AIChatCode",      { bg = shade(base, dir * 26) })

  -- Before/after blocks. Both sit in the blue family rather than red/green:
  -- ORIGINAL is a low-chroma indigo that reads as faded, UPDATE is a brighter,
  -- bluer azure that reads as present. Separated on chroma *and* luminance so
  -- they stay distinguishable without colour-coding correctness.
  local dark = dir == 1
  local old_bg  = dark and 0x2A2E44 or 0xE2E4F0
  local new_bg  = dark and 0x1F4A6B or 0xC6DCF2
  -- blend a little toward the scheme's own ground so it does not look pasted on
  hl(0, "AIChatDiffOld",     { bg = blend(base, old_bg, 0.82) })
  hl(0, "AIChatDiffNew",     { bg = blend(base, new_bg, 0.82) })
  hl(0, "AIChatDiffOldSign", { fg = dark and 0x8A90B0 or 0x5B6180, bold = true })
  hl(0, "AIChatDiffNewSign", { fg = dark and 0x6FC3F5 or 0x1E6FA8, bold = true })
  hl(0, "AIChatDiffFence",   { fg = dark and 0x7E88B8 or 0x565E8C, italic = true })
end

-- ---------------------------------------------------------------------------
-- UI. Nothing below here knows about HTTP.
-- ---------------------------------------------------------------------------
local function side_width()
  return math.floor(vim.o.columns * WIDTH_RATIO)
end

local function ensure_transcript_buffer()
  if vim.api.nvim_buf_is_valid(state.transcript.buf) then
    return state.transcript.buf
  end
  local buf = vim.api.nvim_create_buf(false, true)
  -- markdown, so treesitter's injection queries highlight fenced code blocks
  -- in their own language without us parsing anything ourselves
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  vim.b[buf].ai_role = "transcript"
  pcall(vim.treesitter.start, buf, "markdown")
  pcall(vim.api.nvim_buf_set_name, buf, "AI Companion")
  state.transcript.buf = buf
  return buf
end

local function ensure_input_buffer()
  if vim.api.nvim_buf_is_valid(state.input.buf) then
    return state.input.buf
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "markdown"
  vim.b[buf].ai_role = "input"
  pcall(vim.api.nvim_buf_set_name, buf, "AI Companion Input")

  vim.keymap.set({ "n", "i" }, "<CR>", function() M.submit() end,
    { buffer = buf, desc = "Send message" })
  vim.keymap.set("i", "<C-j>", "<CR>",
    { buffer = buf, desc = "Literal newline" })
  vim.keymap.set({ "n", "i" }, "<C-c>", function() M.cancel() end,
    { buffer = buf, desc = "Cancel request" })

  state.input.buf = buf
  return buf
end

-- Builds the two stacked windows in the left column and returns their handles.
local function create_chat_ui()
  vim.cmd("topleft vsplit")
  local twin = vim.api.nvim_get_current_win()
  local tbuf = ensure_transcript_buffer()
  vim.api.nvim_win_set_buf(twin, tbuf)
  vim.api.nvim_win_set_width(twin, side_width())

  vim.wo[twin].number = false
  vim.wo[twin].relativenumber = false
  vim.wo[twin].signcolumn = "no"
  vim.wo[twin].winfixwidth = true
  vim.wo[twin].wrap = true
  vim.wo[twin].linebreak = true
  vim.wo[twin].cursorline = false
  vim.wo[twin].conceallevel = 0
  -- breakindent puts a *virtual* indent at the start of every wrapped
  -- continuation row. Virtual cells are not buffer columns, so a line
  -- background does not reach them and the indent renders as a coloured stub
  -- against the block. Off here; the global setting still applies everywhere else.
  vim.wo[twin].breakindent = false
  -- listchars ('trail' = "_", 'tab' = "| ") would draw markers through code blocks
  vim.wo[twin].list = false
  vim.wo[twin].winbar = "%#AIChatBar# " .. MODEL_LABEL .. " %*"

  vim.cmd("belowright split")
  local iwin = vim.api.nvim_get_current_win()
  local ibuf = ensure_input_buffer()
  vim.api.nvim_win_set_buf(iwin, ibuf)
  vim.api.nvim_win_set_height(iwin, INPUT_HEIGHT)

  vim.wo[iwin].number = false
  vim.wo[iwin].relativenumber = false
  vim.wo[iwin].signcolumn = "no"
  vim.wo[iwin].winfixheight = true
  vim.wo[iwin].wrap = true
  vim.wo[iwin].linebreak = true
  vim.wo[iwin].breakindent = false
  vim.wo[iwin].list = false
  vim.wo[iwin].winbar = "%#AIChatBar# message %= /help  <CR> send %*"

  return { transcript = { buf = tbuf, win = twin }, input = { buf = ibuf, win = iwin } }
end

local function follow_tail()
  local win, buf = state.transcript.win, state.transcript.buf
  if vim.api.nvim_win_is_valid(win) and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
  end
end

-- Drops the oldest lines once the transcript exceeds MAX_LINES. Safe only
-- between turns; see the call site.
local function trim_transcript()
  local buf = state.transcript.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local count = vim.api.nvim_buf_line_count(buf)
  if count <= MAX_LINES then
    return
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, count - MAX_LINES, false, {})
  vim.bo[buf].modifiable = false
end

-- ORIGINAL / UPDATE block spans, as 0-indexed buffer rows plus which group
-- paints them. Returned separately from code fences because these nest inside
-- a message and carry their own colour.
local function diff_spans(lines, offset)
  local D = require("qvd808.custom.ai.diff")
  local spans, open, group = {}, nil, nil
  for i, line in ipairs(lines) do
    local trimmed = vim.trim(line)
    if trimmed == D.FENCE_OLD_OPEN then
      open, group = offset + i - 1, "AIChatDiffOld"
    elseif trimmed == D.FENCE_NEW_OPEN then
      open, group = offset + i - 1, "AIChatDiffNew"
    elseif (trimmed == D.FENCE_OLD_CLOSE or trimmed == D.FENCE_NEW_CLOSE) and open then
      spans[#spans + 1] = { open, offset + i - 1, group }
      open, group = nil, nil
    end
  end
  if open then
    spans[#spans + 1] = { open, offset + #lines - 1, group }
  end
  return spans
end

-- Fenced code spans within `lines`, as 0-indexed buffer rows.
local function fence_spans(lines, offset)
  local spans, open = {}, nil
  for i, line in ipairs(lines) do
    if line:match("^ ? ? ?```") then
      if open then
        spans[#spans + 1] = { open, offset + i - 1, #line }
        open = nil
      else
        open = offset + i - 1
      end
    end
  end
  if open then -- fence still streaming / never closed
    spans[#spans + 1] = { open, offset + #lines - 1, #lines[#lines] }
  end
  return spans
end

-- Renders one message. Returns the buffer row it starts on.
local function put_message(opts)
  local head = "▌ " .. opts.label
  local label_bytes = #head
  if opts.meta then
    head = head .. "  " .. opts.meta
  end

  local lines = { head }
  if opts.text and opts.text ~= "" then
    lines[#lines + 1] = ""
    for _, l in ipairs(vim.split(opts.text, "\n")) do
      lines[#lines + 1] = l
    end
  end
  lines[#lines + 1] = ""

  local buf = ensure_transcript_buffer()
  local start = opts.at
  if start == nil then
    local count = vim.api.nvim_buf_line_count(buf)
    local only = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    start = (count == 1 and only == "") and 0 or count
  end

  -- Drop marks in the range we overwrite, or the spinner leaks a fresh set
  -- every tick and they stack up on the same line.
  vim.api.nvim_buf_clear_namespace(buf, NS, start, -1)

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, start, -1, false, lines)
  vim.bo[buf].modifiable = false

  local last = start + #lines - 1

  -- line_hl_group, not hl_group + hl_eol. hl_eol only fills past end-of-text
  -- for a *multiline* range covering the EOL, so with ranged marks the fill
  -- stops at the last character: a line of pure indentation renders as a short
  -- coloured stub and blank lines get nothing. line_hl_group colours the whole
  -- screen line by definition, with no edge case for empty or short lines.
  local function paint(from_row, to_row, group, priority)
    for row = from_row, to_row do
      vim.api.nvim_buf_set_extmark(buf, NS, row, 0, {
        line_hl_group = group,
        priority = priority,
      })
    end
  end

  -- Whole-block background: this is what separates the model from you.
  if opts.bg then
    paint(start, last, opts.bg, PRIO_BLOCK)
  end

  -- Code fences get their own background on top of the block background;
  -- treesitter paints the syntax colours over both.
  for _, span in ipairs(fence_spans(lines, start)) do
    paint(span[1], span[2], "AIChatCode", PRIO_CODE)
  end

  -- Before/after blocks paint above code fences, and their -/+ markers and
  -- fence lines get a foreground on top of that.
  for _, span in ipairs(diff_spans(lines, start)) do
    paint(span[1], span[2], span[3], PRIO_CODE + 1)
    local sign_hl = span[3] == "AIChatDiffOld" and "AIChatDiffOldSign" or "AIChatDiffNewSign"
    for row = span[1], span[2] do
      local text = lines[row - start + 1] or ""
      if row == span[1] or row == span[2] then
        vim.api.nvim_buf_set_extmark(buf, NS, row, 0,
          { end_col = #text, hl_group = "AIChatDiffFence", priority = PRIO_HEADER })
      elseif text:sub(1, 1) == "-" or text:sub(1, 1) == "+" then
        vim.api.nvim_buf_set_extmark(buf, NS, row, 0,
          { end_col = 1, hl_group = sign_hl, priority = PRIO_HEADER })
      end
    end
  end

  -- Role header, above treesitter so it is not repainted as markdown prose.
  vim.api.nvim_buf_set_extmark(buf, NS, start, 0, {
    end_col = math.min(label_bytes, #lines[1]),
    hl_group = opts.hl,
    priority = PRIO_HEADER,
  })
  if #lines[1] > label_bytes then
    vim.api.nvim_buf_set_extmark(buf, NS, start, label_bytes, {
      end_col = #lines[1],
      hl_group = "AIChatMeta",
      priority = PRIO_HEADER,
    })
  end

  follow_tail()
  return start
end

-- ---------------------------------------------------------------------------
-- In-flight indicator. Proves the editor is still running while curl works.
-- ---------------------------------------------------------------------------
local function stop_spinner()
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
  local buf = state.transcript.buf
  if vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_del_extmark, buf, NS_SPIN, SPIN_MARK)
  end
end

local function start_spinner()
  state.spin = 1
  state.started = vim.uv.hrtime()

  -- One buffer write to lay down the header. Everything after this is virtual
  -- text: measured at 0.04 ms/tick versus 17.7 ms for rewriting the block,
  -- because an edit invalidates the treesitter tree and an overlay does not.
  state.pending_at = put_message({
    label = MODEL_LABEL,
    hl = "AIChatBot",
    bg = "AIChatAssistant",
  })

  state.timer = vim.uv.new_timer()
  state.timer:start(120, 120, function()
    vim.schedule(function()
      if not state.timer or state.pending_at == nil then
        return
      end
      local buf = state.transcript.buf
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      state.spin = state.spin % #SPINNER + 1
      vim.api.nvim_buf_set_extmark(buf, NS_SPIN, state.pending_at, 0, {
        id = SPIN_MARK,
        virt_text = { { string.format("  %s %.1fs", SPINNER[state.spin],
          (vim.uv.hrtime() - state.started) / 1e9), "AIChatMeta" } },
        virt_text_pos = "eol",
        priority = PRIO_HEADER,
      })
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- Networking. Raw for now: one turn, no history, no retry, no streaming.
-- ---------------------------------------------------------------------------
local function api_key()
  local path = vim.fn.expand(AUTH_PATH)
  if vim.fn.filereadable(path) ~= 1 then
    return nil, path .. " is not readable"
  end
  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok then
    return nil, "could not parse " .. path
  end
  local entry = decoded[PROVIDER]
  if not entry or not entry.key then
    return nil, "no '" .. PROVIDER .. "' key in " .. path
  end
  return entry.key
end

local function fail(msg)
  stop_spinner()
  put_message({ at = state.pending_at, label = "error", hl = "AIChatErr", text = msg })
  state.pending_at = nil
end

local function on_response(res, elapsed_ms)
  stop_spinner()

  if res.code ~= 0 then
    return fail(("curl exited %d\n%s"):format(res.code, vim.trim(res.stderr or "")))
  end

  local ok, decoded = pcall(vim.json.decode, res.stdout or "")
  if not ok then
    return fail("unreadable response\n" .. (res.stdout or ""):sub(1, 300))
  end
  if decoded.error then
    return fail(decoded.error.message or vim.inspect(decoded.error))
  end

  local choice = decoded.choices and decoded.choices[1]
  local message = choice and choice.message or {}
  local content = message.content
  if not content or content == "" then
    -- A tool call legitimately returns content == "". Only the case with
    -- neither content nor tool_calls is actually empty.
    if message.tool_calls and #message.tool_calls > 0 then
      local names = {}
      for _, c in ipairs(message.tool_calls) do
        names[#names + 1] = c["function"] and c["function"].name or "?"
      end
      content = "requested tools: " .. table.concat(names, ", ")
        .. "\n(plain chat has no tool loop -- type /help for workflows)"
    else
      return fail("no content in response")
    end
  end

  state.history[#state.history + 1] = { role = "assistant", content = content }

  local usage = decoded.usage or {}
  local meta = string.format("%.1fs - %d tok", elapsed_ms / 1000, usage.completion_tokens or 0)
  if usage.prompt_cache_hit_tokens and usage.prompt_tokens and usage.prompt_tokens > 0 then
    meta = meta .. string.format(" - %d%% cached", math.floor(
      100 * usage.prompt_cache_hit_tokens / usage.prompt_tokens))
  end
  meta = meta .. string.format(" - %d turns", math.floor(#state.history / 2))

  -- finish_reason == "length" means MAX_TOKENS cut the reply off mid-sentence.
  -- Say so, rather than leaving a silently truncated answer that reads as if
  -- the model just stopped having anything to add.
  if choice.finish_reason == "length" then
    meta = meta .. " - TRUNCATED at max_tokens"
  end

  put_message({
    at = state.pending_at,
    label = MODEL_LABEL,
    hl = "AIChatBot",
    bg = "AIChatAssistant",
    meta = meta,
    text = vim.trim(content),
  })
  state.pending_at = nil
end

local function send(prompt)
  local key, err = api_key()
  if not key then
    return fail(err)
  end

  state.history[#state.history + 1] = { role = "user", content = prompt }
  trim_history()

  local body = vim.json.encode({
    model = MODEL,
    messages = state.history,
    max_tokens = MAX_TOKENS,
    stream = false,
  })

  local started = vim.uv.hrtime()

  -- vim.system returns immediately; the callback lands in a fast event context,
  -- so everything it touches goes through vim.schedule.
  state.job = vim.system({
    "curl", "-sS", "--max-time", "120",
    BASE_URL .. "/chat/completions",
    "-H", "Content-Type: application/json",
    "-H", "Authorization: Bearer " .. key,
    "--data-binary", "@-",
  }, { stdin = body, text = true }, function(res)
    local elapsed = (vim.uv.hrtime() - started) / 1e6
    vim.schedule(function()
      state.job = nil
      on_response(res, elapsed)
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- Workflow dispatch
-- ---------------------------------------------------------------------------
-- A workflow runs isolated: it gets the argument and nothing else. Chat
-- history is deliberately not passed in, so a long conversation cannot leak
-- into a state that was scoped to one job.
local function run_workflow(spec, arg)
  start_spinner()
  state.job = true

  local ctx = {}

  --- Suspend the workflow and put a question to the user. `choices` may be nil
  --- for free text. The job slot and spinner are released while we wait, so
  --- the pane stays usable, and re-acquired when the answer arrives.
  ctx.ask = function(question, choices, resolve)
    state.job = nil
    stop_spinner()
    state.pending_at = nil

    local lines = { question, "" }
    if choices then
      for i, c in ipairs(choices) do
        lines[#lines + 1] = ("%d. **%s** - %s"):format(i, c.label, c.hint or "")
      end
      lines[#lines + 1] = ""
      lines[#lines + 1] = "_reply with a number_"
    end
    put_message({ label = "?", hl = "AIChatMeta", text = table.concat(lines, "\n") })

    state.awaiting = {
      kind = "ask",
      resolve = function(answer)
        answer = vim.trim(answer)
        state.job = true
        start_spinner()
        if not choices then
          return resolve(nil, answer)
        end
        -- People answer "1", "1.", "1. it should compile", or "compile".
        -- Take a leading number if there is one, else match on words.
        local picked = choices[tonumber(answer:match("^%s*(%d+)") or "") or -1]
        if not picked then
          local lowered = answer:lower()
          for _, c in ipairs(choices) do
            if c.id == lowered
              or lowered:find(c.id, 1, true)
              or lowered:find(c.label:lower(), 1, true)
              or c.label:lower():find(lowered, 1, true) then
              picked = c
              break
            end
          end
        end
        resolve(picked, answer)
      end,
    }
  end

  ctx.on_step = function(node, note)
      if state.pending_at == nil or not vim.api.nvim_buf_is_valid(state.transcript.buf) then
        return
      end
      vim.api.nvim_buf_set_extmark(state.transcript.buf, NS_SPIN, state.pending_at, 0, {
        id = SPIN_MARK,
        virt_text = { { ("  [%s] %s"):format(node, note), "AIChatMeta" } },
        virt_text_pos = "eol",
        priority = PRIO_HEADER,
      })
  end

  local ok, err = pcall(spec.run, arg, ctx, function(rerr, result)
    state.job = nil
    stop_spinner()
    if rerr then
      put_message({ at = state.pending_at, label = "/" .. spec.name .. " failed",
                    hl = "AIChatErr", text = rerr })
    else
      put_message({
        at = state.pending_at,
        label = "/" .. spec.name,
        hl = "AIChatBot",
        bg = "AIChatAssistant",
        meta = result.meta,
        text = result.text or "",
      })
    end
    state.pending_at = nil
  end)

  if not ok then
    state.job = nil
    stop_spinner()
    put_message({ at = state.pending_at, label = "/" .. spec.name .. " crashed",
                  hl = "AIChatErr", text = tostring(err) })
    state.pending_at = nil
  end
end

-- ---------------------------------------------------------------------------
-- Public
-- ---------------------------------------------------------------------------
function M.submit()
  if not vim.api.nvim_buf_is_valid(state.input.buf) then
    return
  end
  if state.job then
    vim.notify("AI Companion: a reply is still in flight", vim.log.levels.WARN)
    return
  end

  local prompt = vim.trim(table.concat(
    vim.api.nvim_buf_get_lines(state.input.buf, 0, -1, false), "\n"))
  if prompt == "" then
    return
  end

  vim.api.nvim_buf_set_lines(state.input.buf, 0, -1, false, { "" })

  local workflows = require("qvd808.custom.ai.workflows")

  -- A workflow asked a question last turn; this message is the answer.
  if state.awaiting then
    local pending = state.awaiting
    state.awaiting = nil
    put_message({ label = "you", hl = "AIChatUser", text = prompt })
    if pending.kind == "ask" then
      return pending.resolve(prompt)
    end
    return run_workflow(pending.spec, prompt)
  end

  local name, arg = workflows.parse(prompt)
  if name then
    put_message({ label = "you", hl = "AIChatUser", text = prompt })
    local spec = workflows.get(name)
    if not spec then
      return put_message({
        label = "unknown workflow", hl = "AIChatErr",
        text = "/" .. name .. "\n\ntry: /" .. table.concat(workflows.names(), ", /"),
      })
    end
    -- Invoked bare: ask for the argument instead of guessing at one.
    if arg == "" and spec.prompt then
      state.awaiting = { kind = "arg", spec = spec }
      return put_message({ label = "/" .. spec.name, hl = "AIChatMeta", text = spec.prompt })
    end
    return run_workflow(spec, arg)
  end

  -- Trim between turns, never mid-request: dropping lines would shift
  -- state.pending_at out from under the in-flight reply.
  trim_transcript()
  put_message({ label = "you", hl = "AIChatUser", text = prompt })
  start_spinner()
  send(prompt)
end

function M.cancel()
  if not state.job then
    return
  end
  state.job:kill(15)
  state.job = nil
  stop_spinner()
  put_message({ at = state.pending_at, label = "cancelled", hl = "AIChatMeta" })
  state.pending_at = nil
end

function M.toggle()
  if vim.api.nvim_win_is_valid(state.transcript.win) or vim.api.nvim_win_is_valid(state.input.win) then
    if vim.api.nvim_win_is_valid(state.input.win) then
      vim.api.nvim_win_hide(state.input.win)
    end
    if vim.api.nvim_win_is_valid(state.transcript.win) then
      vim.api.nvim_win_hide(state.transcript.win)
    end
    return
  end

  local first = not vim.api.nvim_buf_is_valid(state.transcript.buf)
  local ui = create_chat_ui()
  state.transcript = ui.transcript
  state.input = ui.input

  if first then
    put_message({
      label = "AI Companion",
      hl = "AIChatMeta",
      text = MODEL_LABEL .. " - type /help for workflows, :AIClear to reset history",
    })
  end

  vim.api.nvim_set_current_win(state.input.win)
  vim.cmd("startinsert")
end

function M.buffer()
  return ensure_transcript_buffer()
end

-- Lets a workflow put a block in the transcript without reaching into locals.
function M.render(opts)
  return put_message(opts)
end


-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------
local group = vim.api.nvim_create_augroup("ai-companion", { clear = true })

vim.api.nvim_create_autocmd("VimResized", {
  group = group,
  desc = "Keep the AI companion pane at a quarter of the editor width",
  callback = function()
    if vim.api.nvim_win_is_valid(state.transcript.win) then
      vim.api.nvim_win_set_width(state.transcript.win, side_width())
    end
  end,
})

vim.api.nvim_create_autocmd("ColorScheme", {
  group = group,
  desc = "Recompute AI companion backgrounds from the new Normal",
  callback = define_highlights,
})

define_highlights()

vim.api.nvim_create_user_command("AICompanion", M.toggle, {})
-- Visual-range rewrite: select a function, :'<,'>AIWrite <goal>
vim.api.nvim_create_user_command("AIWrite", function(o)
  local goal = vim.trim(o.args)
  if goal == "" then
    return vim.notify("AIWrite: give it a goal", vim.log.levels.WARN)
  end
  if state.job then
    return vim.notify("AI Companion: busy", vim.log.levels.WARN)
  end
  if not vim.api.nvim_win_is_valid(state.transcript.win) then
    M.toggle()
    vim.cmd("wincmd p")
  end
  local srow, erow = o.line1, o.line2
  put_message({ label = "you", hl = "AIChatUser",
    text = (":%d,%dAIWrite %s"):format(srow, erow, goal) })
  run_workflow({
    name = "write",
    run = function(_, ctx, cb)
      require("qvd808.custom.ai.write").run_range(srow, erow, goal, ctx, cb)
    end,
  }, goal)
end, { nargs = "+", range = true, desc = "Rewrite the selected range" })

vim.api.nvim_create_user_command("AIClear", function()
  state.history = {}
  put_message({ label = "history cleared", hl = "AIChatMeta" })
end, { desc = "Forget the conversation so far" })
vim.keymap.set("n", "<space>ch", ":AICompanion<CR>", { silent = true, desc = "Toggle AI Companion" })

return M
