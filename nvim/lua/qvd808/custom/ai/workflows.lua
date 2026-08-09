-- Workflow registry.
--
-- A workflow is invoked by typing `/name [args]` in the chat input, so adding
-- one never means adding a Vim command. Register your own from anywhere:
--
--   require("qvd808.custom.ai.workflows").register({
--     name        = "review",
--     description = "Review the working tree",
--     prompt      = "What should I review?",   -- asked when /review has no args
--     run         = function(arg, ctx, cb) ... end,
--   })
--
-- `run` receives the argument string, a ctx with on_step(node, note) for
-- progress, and a callback taking (err, { text = <markdown>, meta = <string> }).
--
-- Workflows are isolated by default: each one owns its own model calls and
-- shares nothing with the chat history or with other workflows. State talks to
-- state through its emitted contract, not through an accumulated conversation.
local M = {}

M.registry = {}

function M.register(spec)
  assert(type(spec) == "table", "workflow spec must be a table")
  assert(type(spec.name) == "string" and spec.name ~= "", "workflow needs a name")
  assert(type(spec.run) == "function", "workflow needs a run(arg, ctx, cb)")
  M.registry[spec.name] = spec
  return spec
end

function M.get(name)
  return M.registry[name]
end

function M.names()
  local out = {}
  for name in pairs(M.registry) do
    out[#out + 1] = name
  end
  table.sort(out)
  return out
end

--- Splits "/plan add a thing" into "plan", "add a thing".
--- Returns nil when the text is not a slash invocation.
function M.parse(text)
  local name, rest = text:match("^/([%w_%-]+)%s*(.*)$")
  if not name then
    return nil
  end
  return name, vim.trim(rest or "")
end

-- ---------------------------------------------------------------------------
-- Built-ins
-- ---------------------------------------------------------------------------
M.register({
  name = "plan",
  description = "Survey the project, read what matters, emit a todo plan",
  prompt = "What do you want to plan?",
  run = function(goal, ctx, cb)
    local plan = require("qvd808.custom.ai.plan")
    plan.run(goal, { on_step = ctx.on_step }, function(err, result, stats)
      if err then
        return cb(err)
      end
      local saved = plan.save(result)
      local meta = ("%.1fs - %d calls, %d files (%d lines) - %d in / %d out tok")
        :format(stats.ms / 1000, stats.calls, stats.files, stats.lines,
          stats.in_tokens, stats.out_tokens)
      local text = plan.to_markdown(result)
      if #stats.skipped > 0 then
        text = text .. "\n\n_unavailable: " .. table.concat(stats.skipped, ", ") .. "_"
      end
      cb(nil, { text = text .. "\n\nsaved: " .. vim.fn.fnamemodify(saved, ":~:."), meta = meta })
    end)
  end,
})

M.register({
  name = "write",
  description = "Write code for the buffer you are in. One call, no project survey",
  prompt = "What should I write?",
  run = function(goal, ctx, cb)
    require("qvd808.custom.ai.write").run(goal, ctx, cb)
  end,
})

M.register({
  name = "help",
  description = "List the workflows you can run",
  run = function(_, _, cb)
    local lines = { "Type `/name` in the message box to run a workflow.", "" }
    for _, name in ipairs(M.names()) do
      local spec = M.registry[name]
      lines[#lines + 1] = ("- `/%s` - %s"):format(name, spec.description or "")
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Anything not starting with `/` is an ordinary chat message."
    cb(nil, { text = table.concat(lines, "\n") })
  end,
})

return M
