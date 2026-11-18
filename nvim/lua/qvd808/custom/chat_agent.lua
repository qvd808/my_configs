local M = {}

local function path()
  return vim.fn.stdpath("state") .. "/codecompanion-agent.json"
end

local function read()
  if vim.fn.filereadable(path()) == 0 then
    return {}
  end
  local data = vim.json.decode(table.concat(vim.fn.readfile(path()), "\n"))
  assert(type(data) == "table", "Invalid chat preferences")
  return data
end

local function update(change)
  local ok, err = pcall(function()
    local data = read()
    change(data)
    vim.fn.mkdir(vim.fn.stdpath("state"), "p")
    local temp = path() .. "." .. vim.fn.getpid() .. ".tmp"
    assert(vim.fn.writefile({ vim.json.encode(data) }, temp) == 0, "Could not save chat preferences")
    local renamed, rename_err = vim.uv.fs_rename(temp, path())
    if not renamed then
      vim.fn.delete(temp)
      error(rename_err)
    end
  end)
  if not ok then
    vim.notify("Could not remember chat preferences: " .. tostring(err), vim.log.levels.WARN)
  end
end

function M.preferred()
  local data = read()
  return type(data.adapter) == "string" and data.adapter ~= "" and data.adapter or "codex"
end

function M.options(name)
  return (read().options or {})[name] or {}
end

function M.remember_agent(name)
  require("codecompanion.config").interactions.chat.adapter = name
  update(function(data)
    data.adapter = name
  end)
end

local function option_key(option)
  -- Categories are portable within an adapter; IDs also cover agents whose
  -- reasoning option has no category.
  return option.category or option.id
end

local function restore(connection)
  local saved = M.options(connection.adapter.name)
  local function apply(models)
    for _, option in ipairs(connection:get_config_options()) do
      if (option.category == "model") == models then
        local value = saved[option_key(option)]
        if value and value ~= option.currentValue then
          for _, choice in ipairs(require("codecompanion.acp").flatten_config_options(option.options or {})) do
            if choice.value == value then
              connection:set_config_option(option.id, value)
              break
            end
          end
        end
      end
    end
  end
  -- Changing the model can replace the available reasoning options.
  apply(true)
  apply(false)
  for _, option in ipairs(connection:get_config_options()) do
    local key = option_key(option)
    if option.category == "model" and saved[key] == option.currentValue then
      for _, adapter in pairs({ connection.adapter, connection.chat and connection.chat.adapter }) do
        adapter.defaults = adapter.defaults or {}
        adapter.defaults.session_config_options = adapter.defaults.session_config_options or {}
        adapter.defaults.session_config_options[key] = option.currentValue
      end
    end
  end
end

local function without_saving(connection, action)
  local previous = connection._qvd_restoring_preferences
  connection._qvd_restoring_preferences = true
  local ok, result = pcall(action)
  connection._qvd_restoring_preferences = previous
  if not ok then
    error(result)
  end
  return result
end

function M.setup()
  local Connection = require("codecompanion.acp")
  if not Connection._qvd_preferences then
    local set_option = Connection.set_config_option
    Connection.set_config_option = function(self, id, value)
      local selected
      for _, option in ipairs(self:get_config_options()) do
        if option.id == id then
          selected = option_key(option)
          break
        end
      end
      local ok = set_option(self, id, value)
      if ok and selected and not self._qvd_restoring_preferences then
        update(function(data)
          data.options = data.options or {}
          data.options[self.adapter.name] = data.options[self.adapter.name] or {}
          data.options[self.adapter.name][selected] = value
        end)
        -- Keep the existing Copilot before-submit guard in sync with choices
        -- made through the generic ACP options picker too.
        for _, adapter in pairs(selected == "model" and { self.adapter, self.chat and self.chat.adapter } or {}) do
          adapter.defaults = adapter.defaults or {}
          adapter.defaults.session_config_options = adapter.defaults.session_config_options or {}
          adapter.defaults.session_config_options[selected] = value
        end
        M.remember_agent(self.adapter.name)
      end
      return ok
    end

    local establish = Connection._establish_session
    Connection._establish_session = function(self, ...)
      local ok = establish(self, ...)
      if ok then
        without_saving(self, function()
          restore(self)
        end)
      end
      return ok
    end

    -- Adapter defaults run after session creation. They must not replace the
    -- saved user choices or be mistaken for fresh user selections.
    local defaults = require("codecompanion.interactions.chat.acp.defaults")
    local apply = defaults.apply
    defaults.apply = function(adapter, connection)
      return without_saving(connection, function()
        apply(adapter, connection)
        restore(connection)
      end)
    end
    Connection._qvd_preferences = true
  end

  local group = vim.api.nvim_create_augroup("codecompanion-agent-preference", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeCompanionChatAdapter",
    callback = function(args)
      local data = args.data or {}
      local name = data.adapter and data.adapter.name
      -- Creation includes an id; explicit adapter changes do not. In
      -- particular, opening a Copilot workflow must not change the default.
      if not data.id and type(name) == "string" and name ~= "" then
        M.remember_agent(name)
      end
    end,
  })
end

return M
