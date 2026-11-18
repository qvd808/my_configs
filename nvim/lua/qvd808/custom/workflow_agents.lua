-- Platform-specific launch settings. Ticket state and review stay in the controller.
local M = {}

function M.copilot(plugin)
  local model = require("qvd808.custom.copilot").preferred_model()
  local command = { "copilot", "--acp", "--stdio", "--context", "long_context", "--plugin-dir", plugin }
  if model then
    vim.list_extend(command, { "--model", model })
  end
  return require("codecompanion.adapters").extend("copilot_acp", {
    defaults = { session_config_options = model and { model = model } or {} },
    commands = { default = command },
  })
end

function M.resolve(name, plugin)
  if name == "copilot_acp" then
    -- The configured Copilot factory adds optional ticket support itself.
    return M.copilot(plugin)
  end
  -- Codex and other ACP platforms retain their configured authentication,
  -- commands, environment and defaults instead of loading built-in defaults.
  return assert(require("codecompanion.adapters").resolve(name), "Unknown agent: " .. tostring(name))
end

return M
