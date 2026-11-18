vim.opt.runtimepath:append(vim.fn.getcwd() .. "/nvim")
local view = require("qvd808.custom.copilot_workflow_view")
local function unit(id, status)
  return { id = id, title = "Ticket " .. id, status = status, attempt = 1,
    approved_attempt = 1, problem = "A concrete problem", todos = {},
    summary = "Ready", decision = "Which option?" }
end
local state = { goal = "UI test", active = 5, units = {} }
for i = 1, 6 do state.units[i] = unit("u" .. i, "running") end
for _, status in ipairs({ "planning", "awaiting_plan", "running", "awaiting_review", "accepted", "needs_decision", "paused" }) do
  state.units[6].status = status
  for _, width in ipairs({ 1, 7, 18, 40, 78, 104 }) do
    local lines, highlights = view.render(state, width)
    for _, line in ipairs(lines) do
      assert(vim.fn.strdisplaywidth(line) <= width, status .. " overflows " .. width .. ": " .. line)
    end
    local gate = false
    for _, h in ipairs(highlights) do
      assert(h.line >= 0 and h.line < #lines)
      if h.start_col then assert(h.end_col <= #lines[h.line + 1]) end
      if h.group:find("Gate") then gate = true end
    end
    assert(gate, "Current state must be highlighted: " .. status)
  end
end
local lines = view.render(state, 104, "u1")
local text = table.concat(lines, "\n")
assert(text:find("▸u1", 1, true), "Selected older unit hidden")
assert(text:find("Older unit · read-only", 1, true))
assert(text:find("decline to planning", 1, true))
state.units[6].status = "needs_decision"
state.units[6].approved_attempt = 0
text = table.concat(view.render(state, 78), "\n")
assert(text:find("answer → Planning", 1, true))
state.units[6].approved_attempt = 1
text = table.concat(view.render(state, 78), "\n")
assert(text:find("answer → Working", 1, true))
view.render({ goal = "Empty", units = {}, active = -1 }, 40)
view.render(nil, 40)
print("Workflow renderer: states, widths, selection and decision paths passed")
vim.cmd("qa!")
