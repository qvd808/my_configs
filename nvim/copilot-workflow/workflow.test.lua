require("lazy").load({ plugins = { "codecompanion.nvim" } })

local workflow = require("qvd808.custom.copilot_workflow")
local Chat = require("codecompanion.interactions.chat")
local saved_submit, saved_input, saved_select = Chat.submit, vim.ui.input, vim.ui.select
local submitted, file, answer
local submissions = 0

Chat.submit = function(chat)
  submitted = chat
  submissions = submissions + 1
end
vim.ui.input = function(_, callback)
  callback(answer)
end

local function state()
  return vim.json.decode(table.concat(vim.fn.readfile(file), "\n"))
end

local function active()
  local data = state()
  return data.units[data.active + 1]
end

local function update(args)
  args.attempt = active().attempt
  args.unit_id = active().id
  local result = vim
    .system({ "node", vim.fn.getcwd() .. "/copilot-workflow/runtime.mjs", "update" }, {
      env = { NVIM_WORKFLOW_FILE = file },
      stdin = vim.json.encode(args),
      text = true,
    })
    :wait()
  assert(result.code == 0, result.stderr)
end

local function approve()
  local data = state()
  local result = vim
    .system({ "node", vim.fn.getcwd() .. "/copilot-workflow/runtime.mjs", "ui" }, {
      env = { NVIM_WORKFLOW_FILE = file },
      stdin = vim.json.encode({ op = "approve", revision = data.revision }),
      text = true,
    })
    :wait()
  assert(result.code == 0, result.stderr)
end

local function plan_and_approve(todos)
  update({ op = "problem", problem = "Agreed problem" })
  update({ op = "plan", todos = todos })
  approve()
end

local function action(key)
  local callback = vim.fn.maparg(key, "n", false, true).callback
  assert(type(callback) == "function", "Missing graph action " .. key)
  callback()
end

local function graph()
  vim.api.nvim_set_current_buf(submitted.bufnr)
  workflow.toggle()
end

local ok, err = xpcall(function()
  local a, b = workflow.adapter(), workflow.adapter()
  assert(a._workflow_file ~= b._workflow_file, "Chats must not share state")
  assert(a.commands.default[4] == "--context" and a.commands.default[5] == "long_context")
  assert(a.env.NVIM_WORKFLOW_RUNTIME():match("/copilot%-workflow/runtime%.mjs$"))

  workflow.toggle()
  answer = "Research and demo are one outcome"
  action("N")
  assert(submitted and submissions == 1, "Starting must submit one task")
  file = workflow.file(submitted)
  assert(state().goal == answer and #state().units == 1)
  assert(workflow.can_submit(submitted))
  assert(submitted.callbacks.on_before_submit, "Submission gate was not installed")

  for _ = 1, 2 do
    vim.api.nvim_set_current_buf(submitted.bufnr)
    action("?")
    local help_buf = vim.api.nvim_get_current_buf()
    assert(help_buf ~= submitted.bufnr, "Help replaced the chat buffer")
    local help = table.concat(vim.api.nvim_buf_get_lines(help_buf, 0, -1, false), "\n")
    assert(help:find("<leader>ac", 1, true) and help:find("New ticket", 1, true), "Workflow help missing")
    assert(help:find("gq", 1, true) and help:find("<leader>cm", 1, true), "Custom chat shortcuts missing")
    assert(help:find("### Keymaps", 1, true), "Built-in help was lost")
    local _, sections = help:gsub("### Workflow controls", "")
    assert(sections == 1, "Cached help duplicated workflow controls")
    assert(not vim.bo[help_buf].modifiable, "Help must remain read-only")
    action("q")
  end

  vim.api.nvim_set_current_buf(submitted.bufnr)
  submitted.current_request = {}
  answer = "Queued clarification"
  require("qvd808.custom.copilot_ui").queue()
  submitted.current_request = nil
  assert(active().status == "planning" and workflow.can_submit(submitted, true), "A new unit starts in planning chat")
  plan_and_approve({ "Research and demo" })
  update({ op = "todo", id = "t1", status = "done", evidence = "Observed result" })
  update({ op = "ready", summary = "Ready together", artifacts = { "demo.lua" } })
  assert(not workflow.can_submit(submitted, true))
  assert(submitted:dispatch_cancellable("on_before_submit"), "Review must cancel a normal submission")
  vim.api.nvim_exec_autocmds("User", {
    pattern = "CodeCompanionChatDone",
    data = { bufnr = submitted.bufnr },
  })
  vim.wait(40, function()
    return false
  end)
  assert(submissions == 1, "Queued follow-up bypassed review")

  vim.api.nvim_exec_autocmds("User", {
    pattern = "CodeCompanionRequestFinished",
    data = { bufnr = submitted.bufnr },
  })
  vim.wait(200, function()
    return require("qvd808.custom.copilot_workflow_view").is_open()
  end)
  assert(require("qvd808.custom.copilot_workflow_view").is_open(), "Review gate did not pop up the workflow")
  local popup = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  assert(popup:find("GATE · move to the next state?", 1, true) and popup:find("[a] accept", 1, true), "Gate banner missing")
  action("q")

  graph()
  vim.ui.select = function(items, _, callback) callback(items[1]) end
  action("a")
  assert(active().status == "awaiting_review", "Pending follow-ups require an explicit choice")
  vim.ui.select = saved_select
  answer = "Include an edge case"
  action("r")
  assert(active().attempt == 2 and active().status == "planning", "Revising returns to planning")
  assert(#active().todos == 0)
  assert(submissions == 2 and workflow.can_submit(submitted))
  assert(state().events[#state().events].detail:find("Queued clarification", 1, true))
  assert(#require("qvd808.custom.copilot_ui").queued_followups(submitted) == 0)
  vim.api.nvim_exec_autocmds("User", {
    pattern = "CodeCompanionChatDone",
    data = { bufnr = submitted.bufnr },
  })
  vim.wait(40, function()
    return false
  end)
  assert(submissions == 2, "Queued context was sent twice")

  plan_and_approve({ "Edge case" })
  update({ op = "todo", id = "t1", status = "done", evidence = "Edge case demonstrated" })
  update({ op = "ready", summary = "Revised outcome" })
  answer = "Optional thought to discard"
  require("qvd808.custom.copilot_ui").queue()
  assert(#require("qvd808.custom.copilot_ui").queued_followups(submitted) == 1, "Idle follow-up was lost at review")
  graph()
  vim.ui.select = function(items, _, callback) callback(items[2]) end
  action("a")
  vim.ui.select = saved_select
  assert(active().status == "accepted")
  assert(#require("qvd808.custom.copilot_ui").queued_followups(submitted) == 0)
  assert(not workflow.can_submit(submitted, true))
  answer = "Implement the next outcome"
  action("n")
  assert(#state().units == 2 and active().status == "planning")
  assert(active().title == answer and submissions == 3)

  assert(active().status == "planning")
  update({ op = "problem", problem = "Second problem" })
  update({ op = "plan", todos = { "Second outcome" }, commands = { "git commit -m second" } })
  vim.api.nvim_exec_autocmds("User", {
    pattern = "CodeCompanionRequestFinished",
    data = { bufnr = submitted.bufnr },
  })
  vim.wait(200, function()
    return require("qvd808.custom.copilot_workflow_view").is_open()
  end)
  local gate = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  assert(gate:find("approve this plan?", 1, true) and gate:find("git commit -m second", 1, true), "Plan gate missing")
  assert(not workflow.can_submit(submitted, true), "Chat must wait while the plan awaits approval")
  action("a")
  assert(active().status == "running" and active().approved_attempt == active().attempt, "a must approve the plan")
  assert(submissions == 4, "Approving must tell the agent to execute")
  assert(not require("qvd808.custom.copilot_workflow_view").is_open(), "Approval should drop back to the chat")
  update({ op = "todo", id = "t1", status = "done", evidence = "Done" })
  update({ op = "ready", summary = "Second ready" })
  graph()
  action("d")
  assert(active().status == "planning" and active().attempt == 2, "d must decline back to planning")
  assert(submissions == 5, "Declining must send the agent back to ask why")
  assert(state().events[#state().events].detail:find("declined", 1, true))
  update({ op = "decision", question = "Which way?" })
  graph()
  action("d")
  assert(active().status == "planning" and submissions == 5, "Decision gate must only reopen the chat")

  local bound = vim
    .system({ "node", vim.fn.getcwd() .. "/copilot-workflow/runtime.mjs", "hook", "start" }, {
      env = { NVIM_WORKFLOW_FILE = file },
      stdin = '{"sessionId":"ui-saved-session"}',
      text = true,
    })
    :wait()
  assert(bound.code == 0, bound.stderr)
  local restored = require("codecompanion").chat({ auto_submit = false })
  vim.api.nvim_exec_autocmds("User", {
    pattern = "CodeCompanionACPChatRestored",
    data = { bufnr = restored.bufnr, session_id = "ui-saved-session" },
  })
  assert(not workflow.can_submit(restored, true), "Generic chat restore bypassed the controller")
  vim.fn.delete(file)
  assert(not workflow.can_submit(submitted, true), "Missing workflow state bypassed the gate")
end, debug.traceback)

Chat.submit, vim.ui.input, vim.ui.select = saved_submit, saved_input, saved_select
if file then
  vim.fn.delete(file)
end
if not ok then
  vim.api.nvim_err_writeln(err)
  vim.cmd("cquit 1")
else
  print("Workflow UI: start, review gate, queue, revise, accept and next passed")
  vim.cmd("qa!")
end
