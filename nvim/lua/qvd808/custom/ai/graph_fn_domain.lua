-- Domain logic for graph function-node asks.
-- Prompt text lives in ai/prompts/graph_fn/*.md (edit those, not this file).
local prompts = require("qvd808.custom.ai.prompts")

local M = {}

--- Light intent tags from the user question (additive; not a router).
function M.intents(question)
  local q = (question or ""):lower()
  local tags = {}
  local function hit(tag, pats)
    for _, p in ipairs(pats) do
      if q:find(p) then
        tags[#tags + 1] = tag
        return
      end
    end
  end
  hit("explain", { "explain", "what does", "what is", "how does", "describe", "purpose", "role" })
  hit("critique", {
    "improv", "lacking", "smell", "bug", "issue", "wrong", "risk",
    "refactor", "better", "clean", "simplif", "optimi", "perf",
  })
  hit("split", {
    "split", "extract", "break up", "decompose", "child function",
    "helper", "factor out",
  })
  hit("implement", {
    "write", "add", "implement", "create", "change", "edit", "patch",
    "fix", "update", "rewrite", "replace",
  })
  hit("trace", {
    "call", "caller", "callee", "flow", "hierarchy", "who uses", "depend",
    "trace", "path",
  })
  if #tags == 0 then
    tags[1] = "general"
  end
  return tags
end

local function must_render(rel, vars)
  local text, err = prompts.render(rel, vars)
  if not text then
    return "ERROR: " .. tostring(err)
  end
  return vim.trim(text) .. "\n"
end

function M.playbooks(intents)
  local seen, chunks = {}, {}
  for _, tag in ipairs(intents or { "general" }) do
    if not seen[tag] then
      seen[tag] = true
      local rel = "graph_fn/playbooks/" .. tag .. ".md"
      local text = select(1, prompts.read(rel))
      if text then
        chunks[#chunks + 1] = vim.trim(text)
      end
    end
  end
  if #chunks == 0 then
    chunks[1] = vim.trim(select(1, prompts.read("graph_fn/playbooks/general.md")) or "")
  end
  return table.concat(chunks, "\n\n") .. "\n"
end

function M.checklist_block()
  return must_render("graph_fn/checklist.md")
end

function M.preamble(intents)
  intents = intents or { "general" }
  return table.concat({
    must_render("graph_fn/preamble.md", { intents = table.concat(intents, ", ") }),
    "",
    M.playbooks(intents),
    M.checklist_block(),
    "---",
    "",
  }, "\n")
end

function M.gather_system(intents)
  intents = intents or { "general" }
  return table.concat({
    must_render("graph_fn/gather.md", { intents = table.concat(intents, ", ") }),
    "",
    M.playbooks(intents),
  }, "\n")
end

function M.answer_system(intents)
  intents = intents or { "general" }
  return table.concat({
    must_render("graph_fn/answer.md", { intents = table.concat(intents, ", ") }),
    "",
    M.playbooks(intents),
    M.checklist_block(),
  }, "\n")
end

function M.wrap(question, body, intents)
  intents = intents or M.intents(question)
  return M.preamble(intents)
    .. body
    .. "\n\n_One-shot mode: answer from this brief only (no further tools)._\n"
end

return M
