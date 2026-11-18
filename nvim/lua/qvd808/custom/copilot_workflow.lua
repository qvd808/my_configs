local M = {}
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))))
local plugin = root .. "/copilot-workflow"
local directory = vim.fn.stdpath("state") .. "/copilot-workflows"
local selected
local chats = {}
local popped = {}
local cache = {}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.WARN, { title = "Copilot workflow" })
end

local function read(file)
  if not file then
    return
  end
  local stat, err, code = vim.uv.fs_stat(file)
  if not stat then
    assert(code == "ENOENT", err)
    return
  end
  local stamp = stat.mtime.sec .. ":" .. stat.mtime.nsec .. ":" .. stat.size
  if cache[file] and cache[file].stamp == stamp then
    return cache[file].state
  end
  local state = vim.json.decode(table.concat(vim.fn.readfile(file), "\n"))
  assert(
    state.version == 1
      and type(state.units) == "table"
      and type(state.active) == "number"
      and state.units[state.active + 1]
      and vim.tbl_contains(
        { "planning", "awaiting_plan", "running", "paused", "needs_decision", "awaiting_review", "accepted" },
        state.units[state.active + 1].status
      ),
    "Unsupported or corrupt workflow state: " .. file
  )
  cache[file] = { stamp = stamp, state = state }
  return state
end

local function mutate(file, args)
  local result = vim
    .system({ "node", plugin .. "/runtime.mjs", "ui" }, {
      env = { NVIM_WORKFLOW_FILE = file },
      stdin = vim.json.encode(args),
      text = true,
    })
    :wait(3000)
  if result.code ~= 0 then
    error(vim.trim(result.stderr ~= "" and result.stderr or "Workflow controller failed"), 0)
  end
  cache[file] = nil
  return vim.json.decode(result.stdout)
end

local function unit(state)
  return state and state.units[state.active + 1]
end

function M.file(chat)
  return chat and chat.adapter and chat.adapter._workflow_file
end

function M.adapter(file, name)
  local required = file ~= nil
  name = name or require("qvd808.custom.chat_agent").preferred()
  file = file
    or (directory .. "/" .. vim.fn.sha256(tostring(vim.uv.hrtime()) .. ":" .. vim.fn.getpid()):sub(1, 24) .. ".json")
  local overrides = {
    _workflow_file = file,
    _workflow_required = required,
    env = {
      NVIM_WORKFLOW_FILE = function()
        return file
      end,
      NVIM_WORKFLOW_RUNTIME = function()
        return plugin .. "/runtime.mjs"
      end,
      NVIM_WORKFLOW_REQUIRED = function()
        return required and "1" or "0"
      end,
    },
  }
  local base = require("qvd808.custom.workflow_agents").resolve(name, plugin)
  return require("codecompanion.adapters").extend(base, overrides)
end

function M.can_submit(chat, quiet)
  if chat and chat._workflow_restore_blocked then
    if not quiet then
      notify("Reopen this saved work unit through <leader>ac then L, not the generic chat restore")
    end
    return false
  end
  local file = M.file(chat)
  local ok, state = pcall(read, file)
  if not ok then
    notify(state, vim.log.levels.ERROR)
    return false
  end
  if not state and chat and chat.adapter._workflow_required then
    notify("Required workflow state is missing; reopen it from <leader>ac", vim.log.levels.ERROR)
    return false
  end
  if not state or unit(state).status == "running" or unit(state).status == "planning" then
    return true
  end
  if not quiet then
    notify("Work unit is " .. unit(state).status .. "; use <leader>ac to review, revise or answer. Draft kept.")
  end
  return false
end

local function prompt(state, message)
  return (
    "Continue this persisted work unit (not a new outcome).\nGoal: %s\n%s\n"
    .. 'Read state with node "$NVIM_WORKFLOW_RUNTIME" get before doing anything; '
    .. "use the controller update here-document from the session instructions to maintain todos and submit review or ask a decision."
  ):format(unit(state).title, message or "")
end

local function create_chat(file, message)
  local state = read(file)
  if state and state.cwd ~= vim.fn.getcwd() then
    error("Change directory to " .. state.cwd .. " before reopening this workflow", 0)
  end
  local chat = require("codecompanion").chat({
    params = { adapter = M.adapter(file) },
    user_prompt = message,
    auto_submit = false,
    stop_context_insertion = true,
  })
  assert(chat, "Could not create Copilot workflow chat")
  chats[file] = chat
  return chat
end

local function existing_chat(file)
  local chat = chats[file]
  if chat and vim.api.nvim_buf_is_valid(chat.bufnr) then
    return chat
  end
end

local function ensure_chat(file)
  local chat = existing_chat(file)
  if chat then
    return chat
  end
  mutate(file, { op = "recover" })
  return create_chat(file)
end

local function send(chat, message)
  assert(not chat.current_request, "Copilot is still working; wait or stop the request first")
  assert(M.can_submit(chat), "The current outcome needs human review")
  chat.ui:open()
  vim.bo[chat.bufnr].modifiable = true
  chat:add_buf_message({ role = "user", content = message })
  chat:submit()
end

local function include_followups(chat, message)
  local pending = require("qvd808.custom.copilot_ui").queued_followups(chat)
  if #pending > 0 then
    message = message .. "\n\nPreviously queued context for this work unit:\n" .. table.concat(pending, "\n\n")
  end
  return message
end

local function start()
  vim.ui.input({ prompt = "Ticket / reviewable outcome: " }, function(goal)
    if not goal or not goal:match("%S") then
      return
    end
    local ok, err = pcall(function()
      local adapter = M.adapter()
      local file = adapter._workflow_file
      local state = mutate(file, { op = "create", goal = goal, cwd = vim.fn.getcwd() })
      selected = file
      local chat =
        create_chat(
          file,
          prompt(
            state,
            "This is a new work unit in the planning phase. Do not start any work yet: talk with the user in chat "
              .. "until you both agree what problem is being solved, then record it and propose a plan."
          )
        )
      chat:submit()
    end)
    if not ok then
      notify(err, vim.log.levels.ERROR)
    end
  end)
end

local function current_file()
  assert(selected and read(selected), "Start or load a workflow first")
  return selected
end

local function feedback(op, label)
  local file = current_file()
  vim.ui.input({ prompt = label }, function(answer)
    if not answer or not answer:match("%S") then
      return
    end
    local ok, err = pcall(function()
      local chat = ensure_chat(file)
      assert(not chat.current_request, "Copilot is still finishing its response; wait or stop it first")
      local message = include_followups(chat, label .. answer)
      local state = mutate(file, { op = op, feedback = message })
      send(chat, prompt(state, message))
      require("qvd808.custom.copilot_ui").clear_followups(chat)
    end)
    if not ok then
      notify(err, vim.log.levels.ERROR)
    end
  end)
end

local function list()
  local files = vim.fn.globpath(directory, "*.json", false, true)
  local entries = {}
  for _, file in ipairs(files) do
    local state = read(file)
    entries[#entries + 1] = { file = file, state = state }
  end
  table.sort(entries, function(a, b)
    return a.state.updated_at > b.state.updated_at
  end)
  vim.ui.select(entries, {
    prompt = "Saved work units",
    format_item = function(entry)
      return ("[%s] %s"):format(unit(entry.state).status, entry.state.goal)
    end,
  }, function(entry)
    if entry then
      selected = entry.file
      require("qvd808.custom.copilot_workflow_view").refresh()
    end
  end)
end

function M.toggle(target)
  local chat = target
    or require("codecompanion").buf_get_chat(vim.api.nvim_get_current_buf())
    or require("codecompanion").last_chat()
  local file = chat and chat._workflow_saved_file or M.file(chat)
  if read(file) then
    selected = file
    if not chat._workflow_restore_blocked then
      chats[file] = chat
    end
  end
  require("qvd808.custom.copilot_workflow_view").toggle(function()
    return read(selected)
  end, {
    start = start,
    list = list,
    chat = function()
      ensure_chat(current_file()).ui:open()
    end,
    accept = function()
      local path = current_file()
      local state = read(path)
      if unit(state).status == "awaiting_plan" then
        local chat = ensure_chat(path)
        assert(not chat.current_request, "Copilot is still working; wait or stop the request first")
        local approved = mutate(path, { op = "approve", revision = state.revision })
        send(
          chat,
          prompt(
            approved,
            "The user approved the plan. Execute it now without asking for approval between steps; stop with a "
              .. "decision update only if something unexpected changes its scope."
          )
        )
        return "close"
      end
      if unit(state).status ~= "awaiting_review" then
        local status = unit(state).status
        local hint = status == "needs_decision"
            and "Press d to answer the pending question in chat."
          or status == "accepted" and "This outcome is already accepted. Use n for the next unit."
          or "The agent must submit a review with recorded passing checks before you can accept it."
        notify("Cannot accept while " .. status .. ". " .. hint, vim.log.levels.WARN)
        return
      end
      local active_chat = existing_chat(path)
      local ui = require("qvd808.custom.copilot_ui")
      local function accept()
        local state = read(path)
        mutate(path, { op = "accept", revision = state.revision })
        if active_chat then
          ui.clear_followups(active_chat)
        end
        notify("Outcome accepted. Use n for your next work unit or N for a new ticket.", vim.log.levels.INFO)
      end
      if active_chat and #ui.queued_followups(active_chat) > 0 then
        vim.ui.select({ "Cancel; use r to include queued context", "Accept and discard queued context" }, {
          prompt = "Unsent follow-ups remain for this outcome",
        }, function(choice)
          if choice == "Accept and discard queued context" then
            local ok, err = pcall(accept)
            if not ok then
              notify(err, vim.log.levels.ERROR)
            end
          end
        end)
      else
        accept()
      end
    end,
    revise = function()
      feedback("revise", "Revision / desired outcome: ")
    end,
    -- d: no typing here. At a review gate it declines and sends the agent back to ask why in chat;
    -- at a decision gate it just opens the chat, where the user replies to the agent's question.
    answer = function()
      local path = current_file()
      local chat = ensure_chat(path)
      assert(not chat.current_request, "Copilot is still working; wait or stop the request first")
      local state = read(path)
      if unit(state).status == "needs_decision" then
        mutate(path, { op = "answer", feedback = "The user will reply to your question in chat." })
        chat.ui:open()
        return
      end
      local message = include_followups(
        chat,
        "The user declined to move this forward. Make no changes yet. Ask them in chat what is missing or wrong "
          .. "and wait for their reply. Only when you both agree again, record the problem and propose a new plan."
      )
      local revised = mutate(path, { op = "revise", feedback = message })
      send(chat, prompt(revised, message))
      require("qvd808.custom.copilot_ui").clear_followups(chat)
    end,
    resume = function()
      local path = current_file()
      local active_chat = ensure_chat(path)
      assert(not active_chat.current_request, "Copilot is still working")
      local message =
        include_followups(active_chat, "Resume after interruption; inspect existing changes and rerun required checks.")
      local state = mutate(path, { op = "resume", feedback = message })
      send(active_chat, prompt(state, message))
      require("qvd808.custom.copilot_ui").clear_followups(active_chat)
    end,
    next = function()
      local path = current_file()
      vim.ui.input({ prompt = "Next reviewable outcome: " }, function(title)
        if not title or not title:match("%S") then
          return
        end
        local ok, err = pcall(function()
          local active_chat = ensure_chat(path)
          assert(not active_chat.current_request, "Copilot is still finishing its response")
          local state = mutate(path, { op = "next", title = title })
          send(active_chat, prompt(state, "The user explicitly started this next work unit."))
        end)
        if not ok then
          notify(err, vim.log.levels.ERROR)
        end
      end)
    end,
  })
end

function M.setup()
  local group = vim.api.nvim_create_augroup("copilot-workflow", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeCompanionACPChatRestored",
    callback = function(args)
      local data = args.data or {}
      local chat = require("codecompanion").buf_get_chat(data.bufnr)
      if not chat then
        return
      end
      for _, path in ipairs(vim.fn.globpath(directory, "*.json", false, true)) do
        local state = read(path)
        if
          (state.session_id == data.session_id or vim.tbl_contains(state.session_ids or {}, data.session_id))
          and path ~= M.file(chat)
        then
          chat._workflow_restore_blocked = true
          chat._workflow_saved_file = path
          notify("Saved work unit found; reopen it through <leader>ac then L to preserve its review gate")
          return
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeCompanionChatCreated",
    callback = function(args)
      local chat = require("codecompanion").buf_get_chat(args.data.bufnr)
      if not chat or not M.file(chat) then
        return
      end
      chats[M.file(chat)] = chat
      chat:add_callback("on_before_submit", function(current_chat)
        return M.can_submit(current_chat)
      end)
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeCompanionRequestFinished",
    callback = function(args)
      local buf = args.data and args.data.bufnr
      vim.schedule(function()
        local chat = buf and require("codecompanion").buf_get_chat(buf)
        local file = chat and M.file(chat)
        local ok, state = pcall(read, file)
        local gated = ok
          and state
          and vim.tbl_contains({ "awaiting_plan", "awaiting_review", "needs_decision" }, unit(state).status)
        if not gated then
          return
        end
        -- Pop up once per gate, not on every redraw or later request in the same state
        local key = file .. ":" .. state.revision
        if popped[file] == key then
          return
        end
        popped[file] = key
        if not require("qvd808.custom.copilot_workflow_view").is_open() then
          M.toggle(chat)
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeCompanionChatStopped",
    callback = function(args)
      local chat = require("codecompanion").buf_get_chat(args.data.bufnr)
      local file = M.file(chat)
      if file and read(file) then
        local ok, err = pcall(mutate, file, { op = "pause" })
        if not ok then
          notify(err, vim.log.levels.ERROR)
        end
      end
    end,
  })
end

return M
