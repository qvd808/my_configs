vim.opt.rtp:append(vim.fn.getcwd())
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local original_stdpath = vim.fn.stdpath
vim.fn.stdpath = function(kind)
  return kind == "state" and root or original_stdpath(kind)
end
local notices = {}
vim.notify = function(message)
  notices[#notices + 1] = tostring(message)
end
local module = require("qvd808.custom.copilot")
local selections = {
  { modelId = "auto", name = "Auto" },
  { modelId = "auto", name = "Auto" },
  { modelId = "claude-sonnet-5.5", name = "Sonnet" },
}
local current = "auto"
local rejected, unconfirmed = false, false
local conn = {
  session_id = "test",
  get_models = function()
    return { currentModelId = current, availableModels = selections }
  end,
  set_model = function(_, id)
    if rejected then
      return false
    end
    if not unconfirmed then
      current = id
    end
    return true
  end,
}
local chat = { adapter = { name = "copilot_acp", defaults = {} }, acp_connection = conn }
chat.add_callback = function(self, name, callback)
  self[name] = callback
end
local fallback = { adapter = { name = "copilot_acp", defaults = {} } }
package.loaded["codecompanion"] = {
  buf_get_chat = function()
    return chat
  end,
  last_chat = function()
    return fallback
  end,
}
package.loaded["codecompanion.adapters"] = {
  extend = function(_, options)
    return options
  end,
}
local chosen = 2
vim.ui.select = function(items, _, callback)
  assert(#items == 2, "Duplicate Auto entries were not removed")
  callback(items[chosen])
end

local ok, err = xpcall(function()
  assert(module.preferred_model() == nil)
  module.setup_models()
  vim.api.nvim_exec_autocmds("User", { pattern = "CodeCompanionChatCreated", data = { bufnr = 1 } })
  module.model()
  vim.wait(200, function()
    return current == "claude-sonnet-5.5"
  end)
  assert(current == "claude-sonnet-5.5", "Model picker did not select Sonnet")
  assert(fallback.adapter.defaults.session_config_options == nil, "Picker changed the wrong chat")
  assert(module.preferred_model() == current)

  package.loaded["qvd808.custom.copilot"] = nil
  local reloaded = require("qvd808.custom.copilot")
  assert(reloaded.preferred_model() == current, "Preference did not survive module reload")
  local adapter = require("qvd808.custom.copilot_workflow").adapter()
  assert(adapter.defaults.session_config_options.model == current)
  assert(adapter.commands.default[#adapter.commands.default - 1] == "--model")
  assert(adapter.commands.default[#adapter.commands.default] == current)

  chat.current_request = {}
  chosen = 1
  module.model()
  vim.wait(200, function()
    return chat._copilot_model_pending
  end)
  assert(chat._copilot_model_pending and current == "claude-sonnet-5.5", "Busy model change was not deferred")
  chat.current_request = nil
  vim.api.nvim_exec_autocmds("User", { pattern = "CodeCompanionChatDone", data = { bufnr = 1 } })
  vim.wait(200, function()
    return current == "auto"
  end)
  assert(current == "auto" and not chat._copilot_model_pending)

  chosen, rejected = 2, true
  module.model()
  vim.wait(200, function()
    return notices[#notices]:find("rejected", 1, true)
  end)
  assert(not module.apply_model(chat), "Rejected model switch was treated as successful")
  assert(chat.on_before_submit(chat) == false, "Failed switch did not stop submission")
  rejected, unconfirmed = false, true
  assert(not module.apply_model(chat), "Unconfirmed switch was treated as successful")
  unconfirmed = false
  assert(module.apply_model(chat) and current == "claude-sonnet-5.5")
  current = "auto"
  assert(
    chat.on_before_submit(chat) and current == "claude-sonnet-5.5",
    "Model reset was not corrected before submission"
  )

  vim.fn.writefile({ "{broken" }, root .. "/copilot-model.json")
  package.loaded["qvd808.custom.copilot"] = nil
  assert(not pcall(require("qvd808.custom.copilot").preferred_model), "Corrupt preference silently fell back to Auto")
end, debug.traceback)

vim.fn.stdpath = original_stdpath
vim.fn.delete(root, "rf")
if not ok then
  vim.api.nvim_err_writeln(err)
  vim.cmd("cquit 1")
else
  print("Copilot model: active chat, persistence, busy changes and server confirmation passed")
  vim.cmd("qa!")
end
