local M = {}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Copilot" })
end

local preferred_model
local model_loaded = false

function M.preferred_model()
  local saved = require("qvd808.custom.chat_agent").options("copilot_acp").model
  if saved then
    return saved
  end
  if not model_loaded then
    local file = vim.fn.stdpath("state") .. "/copilot-model.json"
    local stat, err, code = vim.uv.fs_stat(file)
    if stat then
      local data = vim.json.decode(table.concat(vim.fn.readfile(file), "\n"))
      assert(type(data.model) == "string" and data.model ~= "", "Invalid Copilot model preference: " .. file)
      preferred_model = data.model
    else
      assert(code == "ENOENT", err)
    end
    model_loaded = true
  end
  return preferred_model
end

local function remember_model(model)
  local directory = vim.fn.stdpath("state")
  vim.fn.mkdir(directory, "p")
  local file = directory .. "/copilot-model.json"
  local temp = file .. "." .. vim.fn.getpid() .. ".tmp"
  assert(vim.fn.writefile({ vim.json.encode({ model = model }) }, temp) == 0, "Could not save Copilot model")
  local ok, err = vim.uv.fs_rename(temp, file)
  if not ok then
    vim.fn.delete(temp)
    error(err)
  end
  preferred_model, model_loaded = model, true
end

function M.apply_model(chat)
  local options = chat.adapter.defaults and chat.adapter.defaults.session_config_options
  local desired = options and options.model
  local conn = chat.acp_connection
  if not desired or not conn or not conn.session_id then
    return true
  end
  local ok, err = pcall(function()
    local models = conn:get_models()
    if not models or models.currentModelId ~= desired then
      assert(conn:set_model(desired), "Copilot rejected model " .. desired)
      models = conn:get_models()
      assert(models and models.currentModelId == desired, "Copilot did not confirm model " .. desired)
    end
  end)
  if not ok then
    notify(tostring(err), vim.log.levels.ERROR)
    return false
  end
  return true
end

function M.setup_models()
  local group = vim.api.nvim_create_augroup("copilot-model", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeCompanionChatCreated",
    callback = function(args)
      local chat = require("codecompanion").buf_get_chat(args.data.bufnr)
      if chat and chat.adapter.name == "copilot_acp" then
        chat:add_callback("on_before_submit", M.apply_model)
      end
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeCompanionChatDone",
    callback = function(args)
      vim.schedule(function()
        local chat = require("codecompanion").buf_get_chat(args.data.bufnr)
        if chat and chat._copilot_model_pending and not chat.current_request and M.apply_model(chat) then
          chat._copilot_model_pending = nil
          notify("Model: " .. chat.adapter.defaults.session_config_options.model)
        end
      end)
    end,
  })
end

-- One-line label: the chat title, else the last thing you typed, else the registry description
local function chat_label(e)
  local flat = function(s)
    return (tostring(s):gsub("%s+", " "):gsub("^%s+", ""))
  end
  local chat = require("codecompanion").buf_get_chat(e.bufnr)
  local label = chat and chat.title
  if not label and chat then
    for i = #chat.messages, 1, -1 do
      local m = chat.messages[i]
      if m.role == "user" and type(m.content) == "string" and m.content:match("%S") and not m.content:match("^%s*Sharing") then
        label = m.content
        break
      end
    end
  end
  label = flat(label or e.description or e.name or "chat")
  return #label > 80 and label:sub(1, 79) .. "…" or label
end

-- Picker over every chat open in this nvim (the action palette only lists them under conditions)
function M.chats()
  local entries = require("codecompanion.interactions.shared.registry").list()
  if #entries == 0 then
    return notify("No open chats")
  end
  table.sort(entries, function(a, b)
    return a.bufnr < b.bufnr
  end)
  vim.ui.select(entries, {
    prompt = "Open chats",
    format_item = function(e)
      return ("#%d  %s"):format(e.bufnr, chat_label(e))
    end,
  }, function(e)
    if e then
      e.open()
    end
  end)
end

-- Picker over the models the Copilot agent offers for the current chat's session
function M.model()
  local cc = require("codecompanion")
  local chat = cc.buf_get_chat(vim.api.nvim_get_current_buf()) or cc.last_chat()
  local conn = chat and chat.acp_connection
  local ok, models = false, nil
  if conn then
    ok, models = pcall(conn.get_models, conn)
  end
  if not ok or not models then
    return notify("No Copilot chat with selectable models yet (open a chat and send a message first)", vim.log.levels.WARN)
  end
  -- The agent lists some models twice (e.g. "Auto"); keep the first of each id
  local seen, list = {}, {}
  for _, m in ipairs(models.availableModels) do
    if not seen[m.modelId] then
      seen[m.modelId] = true
      table.insert(list, m)
    end
  end
  vim.ui.select(list, {
    prompt = "Copilot model",
    format_item = function(m)
      return (m.modelId == models.currentModelId and "* " or "  ") .. m.name .. "  (" .. m.modelId .. ")"
    end,
  }, function(m)
    if not m then
      return
    end
    -- Leave any picker coroutine first; the plugin's RPC helper yields when it runs inside one
    vim.schedule(function()
      local saved, err = pcall(function()
        if chat.adapter.name == "copilot_acp" then
          remember_model(m.modelId)
        end
      end)
      if not saved then
        return notify(tostring(err), vim.log.levels.ERROR)
      end
      chat.adapter.defaults = chat.adapter.defaults or {}
      chat.adapter.defaults.session_config_options = chat.adapter.defaults.session_config_options or {}
      chat.adapter.defaults.session_config_options.model = m.modelId
      if chat.current_request then
        chat._copilot_model_pending = true
        return notify("Model: " .. m.name .. " (after the current reply)")
      end
      if M.apply_model(chat) then
        notify("Model: " .. m.name)
      end
    end)
  end)
end

-- /resume titles come from the session's first message, which is injected context for old sessions.
-- Replace them with the first real prompt from the Copilot session store.
local TITLE_SCRIPT = [[
import json, os, sqlite3, sys
db = sqlite3.connect("file:" + os.path.expanduser("~/.copilot/session-store.db") + "?mode=ro", uri=True)
out = {}
for sid in json.load(sys.stdin):
    for (msg,) in db.execute("select user_message from turns where session_id=? order by turn_index", (sid,)):
        text = (msg or "").strip()
        if text and not text.startswith(("Sharing ", "Personal instructions", "<system_notification>")):
            out[sid] = " ".join(text.split())
            break
print(json.dumps(out))
]]

local function fix_session_titles()
  local Connection = require("codecompanion.acp")
  if Connection._titles_fixed then
    return
  end
  local list = Connection.session_list
  Connection.session_list = function(self, opts)
    local sessions = list(self, opts)
    local ids = vim.tbl_map(function(s)
      return s.sessionId
    end, sessions)
    local ok, res = pcall(function()
      return vim.system({ "python3", "-c", TITLE_SCRIPT }, { stdin = vim.json.encode(ids), text = true }):wait(3000)
    end)
    local titles = ok and res.code == 0 and vim.json.decode(res.stdout) or {}
    for _, s in ipairs(sessions) do
      local title = titles[s.sessionId]
      if title then
        s.title = #title > 80 and title:sub(1, 79) .. "…" or title
      end
    end
    return sessions
  end
  Connection._titles_fixed = true
end

-- nvim-cmp runs slash commands inside its own coroutine, which breaks the plugin's ACP requests
-- ("attempt to yield across C-call boundary" on /resume). Run them from a fresh top-level callback.
function M.fix_slash_commands()
  fix_session_titles()
  -- This nvim's LuaJIT has 5.2 compat on, so coroutine.running() returns a thread on the main thread too.
  -- The plugin treats that as "inside its async runner" and yields, which fails. Restore 5.1 semantics.
  if not coroutine._qvd_running then
    local running = coroutine.running
    coroutine._qvd_running = running
    coroutine.running = function()
      local thread, is_main = running()
      if is_main then
        return nil
      end
      return thread
    end
  end

  local slash = require("codecompanion.interactions.chat.slash_commands")
  if slash._deferred then
    return
  end
  local run = slash.run
  slash.run = function(...)
    local args = { n = select("#", ...), ... }
    vim.schedule(function()
      run(unpack(args, 1, args.n))
    end)
  end
  slash._deferred = true
end
-- Write gate integration: the hook (~/.agents/hooks/write-gate.mjs) calls file_changed/refresh over $NVIM
-- after the agent's tool call succeeded.

local function other_window()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].filetype ~= "codecompanion" and vim.api.nvim_win_get_config(win).relative == "" then
      return win
    end
  end
end

-- Opens the file in a window that is not the chat, so the chat stays on one side and the file on the other.
-- With focus = false the cursor stays where it was (used when the agent changes a file while you type).
local function jump_to(item, focus)
  local origin = vim.api.nvim_get_current_win()
  local target = other_window()
  if not target then
    vim.cmd("rightbelow vsplit")
    target = vim.api.nvim_get_current_win()
  end
  if not vim.uv.fs_stat(item.path) then
    notify("New file, not on disk yet: " .. item.path)
  else
    local ok, err = pcall(vim.api.nvim_win_call, target, function()
      vim.cmd("edit " .. vim.fn.fnameescape(item.path))
      pcall(vim.api.nvim_win_set_cursor, 0, { item.line or 1, 0 })
      vim.cmd("normal! zz")
    end)
    if not ok then
      notify("Could not open " .. item.path .. ": " .. tostring(err), vim.log.levels.WARN)
    end
  end
  if focus == false then
    if vim.api.nvim_win_is_valid(origin) then
      vim.api.nvim_set_current_win(origin)
    end
  else
    vim.api.nvim_set_current_win(target)
  end
end

-- Called by the hook after a shell command that changed files in a repo (rm, mv, git ...): nothing to jump to,
-- but buffers and oil should reflect the change
function M.refresh()
  vim.schedule(function()
    vim.cmd("silent! checktime")
    pcall(function()
      require("oil.view").rerender_all_oil_buffers({ refetch = true })
    end)
  end)
  return ""
end

-- Files the agent changed this session, newest first (filled by the hook's postToolUse call)
local changed = {}

-- Called by the hook after an edit tool succeeded: refresh buffers and oil, remember the file, open it
function M.file_changed(file)
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(file), "\n"))
  end)
  os.remove(file)
  if not ok or not data.items or #data.items == 0 then
    return ""
  end
  vim.schedule(function()
    vim.cmd("silent! checktime")
    pcall(function()
      require("oil.view").rerender_all_oil_buffers({ refetch = true })
    end)
    for _, item in ipairs(data.items) do
      changed = vim.tbl_filter(function(c)
        return c.path ~= item.path
      end, changed)
      table.insert(changed, 1, item)
    end
    local last
    for _, item in ipairs(data.items) do
      if item.operation ~= "delete" then
        last = item
      end
    end
    if last then
      jump_to(last, false)
      notify(("Changed %s (+%d -%d)"):format(last.name, last.added, last.removed))
    else
      notify(("Deleted %d file(s)"):format(#data.items))
    end
  end)
  return ""
end

-- Telescope list of files the agent changed this session; Enter opens one in the non-chat window
function M.changes()
  if #changed == 0 then
    return notify("No files changed by the agent yet")
  end
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local conf = require("telescope.config").values
  pickers
    .new({}, {
      prompt_title = "Files changed by Copilot",
      finder = finders.new_table({
        results = changed,
        entry_maker = function(item)
          return {
            value = item,
            display = ("%s  +%d -%d"):format(item.name, item.added, item.removed),
            ordinal = item.name,
            filename = item.path,
            lnum = item.line,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      previewer = conf.grep_previewer({}),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if entry then
            jump_to(entry.value)
          end
        end)
        return true
      end,
    })
    :find()
end

return M
