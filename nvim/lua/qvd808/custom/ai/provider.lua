-- Single source of truth for which model we talk to and how.
-- openai-completions shape; switch provider by changing the constants below.
local M = {}

M.provider   = "deepseek"
M.base_url   = "https://api.deepseek.com"
M.model      = "deepseek-chat"
M.label      = "DeepSeek V3"

-- deepseek-chat allows 8192. Keep this generous: a small cap does not save
-- money, it just converts one response into several round trips, and each
-- continuation re-sends everything before it.
M.max_tokens = 8192

function M.auth_path()
  return vim.fn.stdpath("config") .. "/auth.json"
end

function M.key()
  local path = M.auth_path()
  if vim.fn.filereadable(path) ~= 1 then
    return nil, path .. " is not readable — copy auth.json.example to auth.json and paste your key"
  end
  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok then
    return nil, "could not parse " .. path
  end
  local entry = decoded[M.provider]
  if not entry or not entry.key or entry.key == ""
    or entry.key == "PASTE_YOUR_DEEPSEEK_API_KEY_HERE" then
    return nil, "no '" .. M.provider .. "' key in " .. path
  end
  return entry.key
end

--- One chat completion.
--- @param opts table messages, tools?, tool_choice?, max_tokens?
--- @param cb fun(err: string|nil, choice: table|nil, usage: table|nil, elapsed_ms: number)
--- @return table|nil handle  vim.system handle, for cancellation
function M.chat(opts, cb)
  local key, kerr = M.key()
  if not key then
    vim.schedule(function() cb(kerr) end)
    return nil
  end

  local payload = {
    model = M.model,
    messages = opts.messages,
    max_tokens = opts.max_tokens or M.max_tokens,
    stream = false,
  }
  if opts.tools then
    payload.tools = opts.tools
    payload.tool_choice = opts.tool_choice or "auto"
  end

  local started = vim.uv.hrtime()
  return vim.system({
    "curl", "-sS", "--max-time", "180",
    M.base_url .. "/chat/completions",
    "-H", "Content-Type: application/json",
    "-H", "Authorization: Bearer " .. key,
    "--data-binary", "@-",
  }, { stdin = vim.json.encode(payload), text = true }, function(res)
    local elapsed = (vim.uv.hrtime() - started) / 1e6
    -- fast event context: hand everything back on the main loop
    vim.schedule(function()
      if res.code ~= 0 then
        return cb(("curl exited %d\n%s"):format(res.code, vim.trim(res.stderr or "")), nil, nil, elapsed)
      end
      local ok, decoded = pcall(vim.json.decode, res.stdout or "")
      if not ok then
        return cb("unreadable response\n" .. (res.stdout or ""):sub(1, 300), nil, nil, elapsed)
      end
      if decoded.error then
        return cb(decoded.error.message or vim.inspect(decoded.error), nil, nil, elapsed)
      end
      local choice = decoded.choices and decoded.choices[1]
      if not choice then
        return cb("no choices in response", nil, nil, elapsed)
      end
      cb(nil, choice, decoded.usage or {}, elapsed)
    end)
  end)
end

return M
