-- Stable editor callback for the shared write gate. Keep the existing change
-- viewer as the implementation so Copilot mappings and change history survive.
local M = {}
function M.refresh(argument)
  return require("qvd808.custom.copilot").refresh(argument)
end
function M.file_changed(argument)
  return require("qvd808.custom.copilot").file_changed(argument)
end
return M
