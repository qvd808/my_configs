vim.opt.rtp:append(vim.fn.getcwd())
local data = vim.fn.stdpath("data")
vim.opt.rtp:append(data .. "/lazy/codecompanion.nvim")
vim.opt.rtp:append(data .. "/lazy/plenary.nvim")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local stdpath = vim.fn.stdpath
vim.fn.stdpath = function(kind)
  return kind == "state" and root or stdpath(kind)
end
local Connection = require("codecompanion.acp")
local defaults = require("codecompanion.interactions.chat.acp.defaults")
local config = require("codecompanion.config")
local preferences = require("qvd808.custom.chat_agent")
local function metadata()
  return {
    { id = "model_id", category = "model", type = "select", currentValue = "sol", options = {
      { value = "sol", name = "Sol" }, { value = "other", name = "Other" },
    } },
    -- IDs must also work for agents which omit categories.
    { id = "reasoning_effort", type = "select", currentValue = "medium", options = {
      { value = "medium", name = "Medium" }, { value = "low", name = "Low" },
    } },
  }
end
local calls, rejected = {}, false
local function connection(name)
  local conn = Connection.new({ adapter = { name = name, defaults = { session_config_options = { model = "sol" } } } })
  conn.adapter_modified = vim.deepcopy(conn.adapter)
  conn.send_rpc_request = function(self, method, args)
    if method == "session/new" then
      return { sessionId = "new", configOptions = metadata() }
    end
    assert(method == "session/set_config_option", method)
    if rejected then return nil end
    calls[#calls + 1] = args.configId
    local options = vim.deepcopy(self:get_config_options())
    for _, option in ipairs(options) do
      if option.id == args.configId then option.currentValue = args.value end
      if args.configId == "model_id" and option.id == "reasoning_effort" then option.currentValue = "medium" end
    end
    return { configOptions = options }
  end
  return conn
end
local function event(data)
  vim.api.nvim_exec_autocmds("User", { pattern = "CodeCompanionChatAdapter", data = data })
end
local ok, err = xpcall(function()
  preferences.setup()
  event({ adapter = { name = "codex" } })
  event({ id = "workflow", adapter = { name = "copilot_acp" } })
  event({})
  assert(preferences.preferred() == "codex", "Creation/close changed preferred agent")
  assert(config.interactions.chat.adapter == "codex")
  local conn = connection("codex")
  assert(conn:_establish_session())
  defaults.apply(conn.adapter, conn)
  assert(next(preferences.options("codex")) == nil, "Agent defaults became preferences")
  assert(conn:set_model("other"))
  assert(conn:set_config_option("reasoning_effort", "low"))
  rejected = true
  assert(not conn:set_config_option("reasoning_effort", "medium"))
  rejected = false
  assert(preferences.options("codex").reasoning_effort == "low", "Failed change was saved")
  package.loaded["qvd808.custom.chat_agent"] = nil
  local reloaded = require("qvd808.custom.chat_agent")
  assert(reloaded.preferred() == "codex")
  assert(reloaded.options("codex").model == "other")
  local fresh = connection("codex")
  calls = {}
  assert(fresh:_establish_session())
  assert(calls[1] == "model_id" and calls[2] == "reasoning_effort", "Restored effort before model")
  defaults.apply(fresh.adapter, fresh)
  assert(fresh:get_models().currentModelId == "other")
  assert(fresh:get_config_options()[2].currentValue == "low", "Reasoning did not survive reopening")
  assert(fresh.adapter.defaults.session_config_options.model == "other", "Stale before-submit default")
  local copilot = connection("copilot_acp")
  assert(copilot:_establish_session())
  assert(copilot:get_models().currentModelId == "sol", "Codex preference leaked to Copilot")
  assert(copilot:set_config_option("reasoning_effort", "low"))
  local fresh_copilot = connection("copilot_acp")
  assert(fresh_copilot:_establish_session())
  defaults.apply(fresh_copilot.adapter, fresh_copilot)
  assert(fresh_copilot:get_config_options()[2].currentValue == "low")
  assert(preferences.options("codex").model == "other")
  local reduced = connection("codex")
  local send = reduced.send_rpc_request
  reduced.send_rpc_request = function(self, method, args)
    local result = send(self, method, args)
    if method == "session/new" then result.configOptions[2].options = { { value = "medium" } } end
    return result
  end
  assert(reduced:_establish_session())
  assert(reduced:get_config_options()[2].currentValue == "medium")
  assert(preferences.options("codex").reasoning_effort == "low")
end, debug.traceback)
vim.fn.stdpath = stdpath
vim.fn.delete(root, "rf")
if not ok then
  vim.api.nvim_err_writeln(err)
  vim.cmd("cquit 1")
else
  print("ACP preferences: agent, model, effort, restart, isolation and rejection checks passed")
  vim.cmd("qa!")
end
