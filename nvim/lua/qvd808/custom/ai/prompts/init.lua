-- Load markdown prompts from ai/prompts/.
local M = {}

local function root()
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) == "@" then
    return vim.fs.dirname(src:sub(2))
  end
  return vim.fn.stdpath("config") .. "/lua/qvd808/custom/ai/prompts"
end

local cache = {}

--- Read a prompt file relative to ai/prompts/ (e.g. "graph_fn/gather.md").
function M.read(rel)
  if cache[rel] then
    return cache[rel]
  end
  local path = root() .. "/" .. rel
  if vim.fn.filereadable(path) ~= 1 then
    return nil, "missing prompt: " .. path
  end
  local text = table.concat(vim.fn.readfile(path), "\n")
  cache[rel] = text
  return text
end

--- Substitute {{key}} placeholders.
function M.render(rel, vars)
  local text, err = M.read(rel)
  if not text then
    return nil, err
  end
  vars = vars or {}
  text = text:gsub("{{([%w_]+)}}", function(key)
    local v = vars[key]
    if v == nil then
      return "{{" .. key .. "}}"
    end
    return tostring(v)
  end)
  return text
end

function M.clear_cache()
  cache = {}
end

return M
