-- Function-node ask as an explicit workflow state machine (not global ReAct).
--
--   brief  → gather
--   gather → gather   (evidence tools)
--   gather → answer   (proceed_to_answer, or gather budget exhausted)
--   answer → done     (emit_answer accepted)
--   answer → gather   (emit_answer rejected / insufficient)
--   *      → fail     (hard limits)
--
-- /plan and other DAGs stay non-looping; only this workflow opts into loops.
local provider = require("qvd808.custom.ai.provider")
local domain = require("qvd808.custom.ai.graph_fn_domain")

local M = {}

local MAX_GATHER = 6
local MAX_ANSWER_TRIES = 2
local MAX_TRANSITIONS = 14
local READ_MAX_LINES = 200
local TOOL_RESULT_MAX = 12000
local MIN_ANSWER_CHARS = 80

local function tool_def(name, description, parameters)
  return {
    type = "function",
    ["function"] = {
      name = name,
      description = description,
      parameters = parameters,
    },
  }
end

local EVIDENCE_TOOLS = {
  tool_def("read_range", "Read a slice of a project file (1-based lines).", {
    type = "object",
    properties = {
      path = { type = "string" },
      start_line = { type = "integer" },
      end_line = { type = "integer" },
    },
    required = { "path" },
  }),
  tool_def("hover", "LSP hover at a position (docs / type / signature text).", {
    type = "object",
    properties = {
      path = { type = "string" },
      line = { type = "integer", description = "1-based" },
      character = { type = "integer", description = "0-based column, default 0" },
    },
    required = { "path", "line" },
  }),
  tool_def("signature", "LSP signatureHelp at a position.", {
    type = "object",
    properties = {
      path = { type = "string" },
      line = { type = "integer", description = "1-based" },
      character = { type = "integer" },
    },
    required = { "path", "line" },
  }),
  tool_def("list_symbols", "List functions/methods in a file via documentSymbol.", {
    type = "object",
    properties = { path = { type = "string" } },
    required = { "path" },
  }),
  tool_def("grep", "Search the project for a fixed string.", {
    type = "object",
    properties = { pattern = { type = "string" } },
    required = { "pattern" },
  }),
  tool_def("graph_neighbors", "Callers/callees of the focus node from the saved graph.", {
    type = "object",
    properties = {
      direction = { type = "string", enum = { "callers", "callees", "both" } },
      with_snippets = { type = "boolean" },
    },
  }),
}

local PROCEED_TOOL = tool_def(
  "proceed_to_answer",
  "Leave gather and enter answer. Only when evidence is enough for the checklist.",
  {
    type = "object",
    properties = {
      reason = { type = "string" },
      still_missing = {
        type = "array",
        items = { type = "string" },
        description = "Known gaps you will disclose in the answer",
      },
    },
    required = { "reason" },
  }
)

local ANSWER_TOOL = tool_def(
  "emit_answer",
  "Final user-facing answer. Must cover the fulfillment checklist.",
  {
    type = "object",
    properties = {
      answer = { type = "string", description = "Markdown answer for the user" },
      checklist = {
        type = "object",
        properties = {
          behavior = { type = "string" },
          interface = { type = "string" },
          architecture = { type = "string" },
          user_ask = { type = "string" },
          gaps = { type = "string" },
        },
        required = { "behavior", "interface", "architecture", "user_ask" },
      },
    },
    required = { "answer", "checklist" },
  }
)

local GATHER_TOOLS = {}
for _, t in ipairs(EVIDENCE_TOOLS) do
  GATHER_TOOLS[#GATHER_TOOLS + 1] = t
end
GATHER_TOOLS[#GATHER_TOOLS + 1] = PROCEED_TOOL
local ANSWER_TOOLS = { ANSWER_TOOL }

local function project_root()
  local found = vim.fs.find(".git", { path = vim.fn.getcwd(), upward = true })[1]
  return found and vim.fs.dirname(found) or vim.fn.getcwd()
end

local function abs_path(path)
  if not path or path == "" then
    return nil
  end
  if path:sub(1, 1) == "/" then
    return path
  end
  return vim.fs.normalize(project_root() .. "/" .. path)
end

local function buf_for(path)
  local abs = abs_path(path)
  if not abs or vim.fn.filereadable(abs) ~= 1 then
    return nil, "unreadable: " .. tostring(path)
  end
  local buf = vim.fn.bufadd(abs)
  vim.fn.bufload(buf)
  return buf, abs
end

local function has_method(bufnr, method)
  for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    if c:supports_method(method) then
      return true
    end
  end
  return false
end

local function clip(s)
  s = tostring(s or "")
  if #s > TOOL_RESULT_MAX then
    return s:sub(1, TOOL_RESULT_MAX) .. "\n…truncated…"
  end
  return s
end

local function exec_evidence(name, args, session)
  args = args or {}
  if name == "read_range" then
    local buf, err = buf_for(args.path)
    if not buf then
      return err
    end
    local total = vim.api.nvim_buf_line_count(buf)
    local s = math.max(1, tonumber(args.start_line) or 1)
    local e = math.min(total, tonumber(args.end_line) or (s + READ_MAX_LINES - 1))
    if e < s then
      e = s
    end
    if e - s + 1 > READ_MAX_LINES then
      e = s + READ_MAX_LINES - 1
    end
    local lines = vim.api.nvim_buf_get_lines(buf, s - 1, e, false)
    return clip(("```%s:%d-%d\n%s\n```"):format(args.path, s, e, table.concat(lines, "\n")))
  end

  if name == "hover" then
    local buf, err = buf_for(args.path)
    if not buf then
      return err
    end
    if not has_method(buf, "textDocument/hover") then
      return "hover not supported"
    end
    local line = math.max(0, (tonumber(args.line) or 1) - 1)
    local col = tonumber(args.character) or 0
    local results = vim.lsp.buf_request_sync(buf, "textDocument/hover", {
      textDocument = vim.lsp.util.make_text_document_params(buf),
      position = { line = line, character = col },
    }, 2500)
    if not results then
      return "hover timed out"
    end
    for _, res in pairs(results) do
      if res.result and res.result.contents then
        local md = vim.lsp.util.convert_input_to_markdown_lines(res.result.contents)
        local text = vim.trim(table.concat(md, "\n"))
        if text ~= "" then
          return clip(text)
        end
      end
    end
    return "no hover"
  end

  if name == "signature" then
    local buf, err = buf_for(args.path)
    if not buf then
      return err
    end
    if not has_method(buf, "textDocument/signatureHelp") then
      return "signatureHelp not supported"
    end
    local line = math.max(0, (tonumber(args.line) or 1) - 1)
    local col = tonumber(args.character) or 0
    local results = vim.lsp.buf_request_sync(buf, "textDocument/signatureHelp", {
      textDocument = vim.lsp.util.make_text_document_params(buf),
      position = { line = line, character = col },
    }, 2500)
    if not results then
      return "signature timed out"
    end
    for _, res in pairs(results) do
      local sigs = res.result and res.result.signatures
      if sigs and #sigs > 0 then
        local out = {}
        for _, s in ipairs(sigs) do
          out[#out + 1] = s.label or ""
        end
        return clip(table.concat(out, "\n"))
      end
    end
    return "no signature"
  end

  if name == "list_symbols" then
    local buf, err = buf_for(args.path)
    if not buf then
      return err
    end
    if not has_method(buf, "textDocument/documentSymbol") then
      return "documentSymbol not supported"
    end
    local results = vim.lsp.buf_request_sync(buf, "textDocument/documentSymbol", {
      textDocument = vim.lsp.util.make_text_document_params(buf),
    }, 2500)
    if not results then
      return "documentSymbol timed out"
    end
    local FN = {
      [vim.lsp.protocol.SymbolKind.Function] = true,
      [vim.lsp.protocol.SymbolKind.Method] = true,
      [vim.lsp.protocol.SymbolKind.Constructor] = true,
    }
    local out = {}
    local function walk(items)
      for _, s in ipairs(items or {}) do
        if FN[s.kind] and s.name then
          local r = s.selectionRange or s.range
          local line = r and r.start and r.start.line or 0
          out[#out + 1] = ("- `%s` @ %d%s"):format(
            s.name, line + 1, s.detail and (" — " .. s.detail) or "")
        end
        if s.children then
          walk(s.children)
        end
      end
    end
    for _, res in pairs(results) do
      walk(res.result)
    end
    if #out == 0 then
      return "no function symbols"
    end
    return clip(table.concat(out, "\n"))
  end

  if name == "grep" then
    local pattern = tostring(args.pattern or "")
    if pattern == "" then
      return "empty pattern"
    end
    if vim.fn.executable("rg") ~= 1 then
      return "rg not installed"
    end
    local res = vim.system({
      "rg", "-n", "-S", "-F", "-m", "20",
      "--glob", "!.git", "--glob", "!node_modules", "--glob", "!.aicompanion",
      "-e", pattern, ".",
    }, { text = true, cwd = project_root() }):wait()
    if (res.code == 0 or res.code == 1) and res.stdout and res.stdout ~= "" then
      return clip(res.stdout)
    end
    return "no matches"
  end

  if name == "graph_neighbors" then
    local graph, node = session.graph, session.node
    if not graph or not node then
      return "no graph session"
    end
    local dir = args.direction or "both"
    local by_id = {}
    for _, n in ipairs(graph.nodes or {}) do
      by_id[n.id] = n
    end
    local callers, callees = {}, {}
    for _, e in ipairs(graph.edges or {}) do
      if e.kind == "calls" then
        if e.to == node.id and by_id[e.from] then
          callers[#callers + 1] = by_id[e.from]
        elseif e.from == node.id and by_id[e.to] then
          callees[#callees + 1] = by_id[e.to]
        end
      end
    end
    local lines = {}
    local function dump(title, list)
      lines[#lines + 1] = "### " .. title
      if #list == 0 then
        lines[#lines + 1] = "_none_"
        return
      end
      for i, n in ipairs(list) do
        lines[#lines + 1] = ("- `%s` in `%s` @ %d"):format(
          n.name or n.label, n.path or "?", (n.line or 0) + 1)
        if args.with_snippets and i <= 3 and n.path then
          local b = select(1, buf_for(n.path))
          if b then
            local s = (n.line or 0) + 1
            local e = math.min(vim.api.nvim_buf_line_count(b), s + 15)
            local body = table.concat(vim.api.nvim_buf_get_lines(b, s - 1, e, false), "\n")
            lines[#lines + 1] = "```\n" .. body .. "\n```"
          end
        end
      end
    end
    if dir == "callers" or dir == "both" then
      dump("Callers", callers)
    end
    if dir == "callees" or dir == "both" then
      dump("Callees", callees)
    end
    return clip(table.concat(lines, "\n"))
  end

  return "unknown evidence tool: " .. tostring(name)
end

local function validate_answer(args)
  if type(args) ~= "table" then
    return nil, "arguments were not an object"
  end
  local answer = vim.trim(tostring(args.answer or ""))
  if #answer < MIN_ANSWER_CHARS then
    return nil, ("answer too short (%d chars, need ≥%d)"):format(#answer, MIN_ANSWER_CHARS)
  end
  local cl = args.checklist
  if type(cl) ~= "table" then
    return nil, "checklist object required"
  end
  for _, key in ipairs({ "behavior", "interface", "architecture", "user_ask" }) do
    if type(cl[key]) ~= "string" or vim.trim(cl[key]) == "" then
      return nil, "checklist." .. key .. " must be a non-empty string"
    end
  end
  return { answer = answer, checklist = cl }
end

--- @param opts table graph, node, question, brief?, on_step?
--- @param cb fun(err, answer, stats)
function M.run(opts, cb)
  opts = opts or {}
  local graph = opts.graph
  local node = opts.node
  local question = opts.question or ""
  local on_step = opts.on_step or function() end
  local brief = opts.brief
  if not brief then
    local graph_mod = require("qvd808.custom.ai.graph")
    brief = select(1, graph_mod.pack_ask(graph, node.id, question))
  end

  local intents = domain.intents(question)
  local session = { graph = graph, node = node }
  local messages = {}
  local stats = {
    state = "brief",
    transitions = 0,
    gather = 0,
    answer_tries = 0,
    tools = 0,
    in_tokens = 0,
    out_tokens = 0,
    ms = 0,
    path = { "brief" },
  }

  local function bump_usage(usage, ms)
    stats.in_tokens = stats.in_tokens + (usage and usage.prompt_tokens or 0)
    stats.out_tokens = stats.out_tokens + (usage and usage.completion_tokens or 0)
    stats.ms = stats.ms + (ms or 0)
  end

  local enter

  local function transition(next_state, note)
    stats.transitions = stats.transitions + 1
    stats.path[#stats.path + 1] = next_state
    stats.state = next_state
    on_step("state", next_state .. (note and (" · " .. note) or ""))
    if stats.transitions > MAX_TRANSITIONS then
      return cb("state machine exceeded " .. MAX_TRANSITIONS .. " transitions", nil, stats)
    end
    enter(next_state)
  end

  local function run_gather()
    stats.gather = stats.gather + 1
    if stats.gather > MAX_GATHER then
      messages[#messages + 1] = {
        role = "user",
        content = "GATHER budget exhausted. Proceed to ANSWER with what you have; disclose gaps.",
      }
      return transition("answer", "gather budget")
    end

    on_step("gather", ("round %d/%d"):format(stats.gather, MAX_GATHER))
    provider.chat({
      messages = messages,
      tools = GATHER_TOOLS,
      tool_choice = "auto",
    }, function(err, choice, usage, ms)
      if err then
        return cb(err, nil, stats)
      end
      bump_usage(usage, ms)
      local msg = choice.message or {}
      messages[#messages + 1] = msg

      local calls = msg.tool_calls or {}
      if #calls == 0 then
        -- No tool call: nudge toward proceed or force answer soon.
        messages[#messages + 1] = {
          role = "user",
          content = "In GATHER you must call tools or proceed_to_answer. "
            .. "If the brief is enough, call proceed_to_answer now.",
        }
        if stats.gather >= MAX_GATHER then
          return transition("answer", "no tools")
        end
        return transition("gather", "retry empty")
      end

      local proceed = false
      local proceed_note = nil
      for _, call in ipairs(calls) do
        local fname = call["function"] and call["function"].name or ""
        local ok, args = pcall(vim.json.decode, call["function"].arguments or "{}")
        if not ok then
          args = {}
        end
        stats.tools = stats.tools + 1
        on_step("tool", fname)

        if fname == "proceed_to_answer" then
          proceed = true
          proceed_note = args.reason or "ready"
          local missing = args.still_missing
          local content = "proceed ok"
          if type(missing) == "table" and #missing > 0 then
            content = "proceed ok; still_missing: " .. table.concat(missing, "; ")
          end
          messages[#messages + 1] = {
            role = "tool",
            tool_call_id = call.id,
            content = content,
          }
        elseif fname == "emit_answer" then
          messages[#messages + 1] = {
            role = "tool",
            tool_call_id = call.id,
            content = "REJECTED: emit_answer is only valid in ANSWER state. Call proceed_to_answer first.",
          }
        else
          local result = exec_evidence(fname, args, session)
          messages[#messages + 1] = {
            role = "tool",
            tool_call_id = call.id,
            content = tostring(result),
          }
        end
      end

      if proceed then
        return transition("answer", proceed_note)
      end
      return transition("gather", "more evidence")
    end)
  end

  local function run_answer()
    stats.answer_tries = stats.answer_tries + 1
    if stats.answer_tries > MAX_ANSWER_TRIES then
      return cb("answer rejected too many times", nil, stats)
    end

    on_step("answer", ("try %d/%d"):format(stats.answer_tries, MAX_ANSWER_TRIES))
    messages[#messages + 1] = {
      role = "user",
      content = table.concat({
        "STATE → ANSWER.",
        "Call emit_answer with a full markdown answer and checklist",
        "(behavior, interface, architecture, user_ask; gaps if needed).",
      }, " "),
    }

    local send_msgs = { { role = "system", content = domain.answer_system(intents) } }
    for i, m in ipairs(messages) do
      if not (i == 1 and m.role == "system") then
        send_msgs[#send_msgs + 1] = m
      end
    end

    provider.chat({
      messages = send_msgs,
      tools = ANSWER_TOOLS,
      tool_choice = { type = "function", ["function"] = { name = "emit_answer" } },
    }, function(err, choice, usage, ms)
      if err then
        return cb(err, nil, stats)
      end
      bump_usage(usage, ms)
      local msg = choice.message or {}
      messages[#messages + 1] = msg

      local call = msg.tool_calls and msg.tool_calls[1]
      if not call or not call["function"] or call["function"].name ~= "emit_answer" then
        messages[#messages + 1] = {
          role = "user",
          content = "REJECTED: you must call emit_answer. Returning to GATHER to fetch what you need, then ANSWER again.",
        }
        return transition("gather", "missing emit_answer")
      end

      local ok, args = pcall(vim.json.decode, call["function"].arguments or "{}")
      local value, verr = nil, "bad json"
      if ok then
        value, verr = validate_answer(args)
      end

      if not value then
        messages[#messages + 1] = {
          role = "tool",
          tool_call_id = call.id,
          content = "REJECTED: " .. tostring(verr),
        }
        messages[#messages + 1] = {
          role = "user",
          content = "ANSWER contract failed (" .. tostring(verr)
            .. "). Back to GATHER for missing evidence, then proceed_to_answer again.",
        }
        return transition("gather", "answer rejected")
      end

      messages[#messages + 1] = {
        role = "tool",
        tool_call_id = call.id,
        content = "accepted",
      }
      stats.state = "done"
      stats.path[#stats.path + 1] = "done"
      on_step("state", "done")
      cb(nil, value.answer, stats)
    end)
  end

  enter = function(state_name)
    if state_name == "gather" then
      return run_gather()
    end
    if state_name == "answer" then
      return run_answer()
    end
    if state_name == "fail" then
      return cb("workflow entered fail", nil, stats)
    end
    return cb("unknown state: " .. tostring(state_name), nil, stats)
  end

  -- brief → gather
  on_step("state", "brief")
  messages[1] = { role = "system", content = domain.gather_system(intents) }
  messages[2] = {
    role = "user",
    content = table.concat({
      domain.preamble(intents),
      brief or "",
      "",
      "STATE → GATHER. Use evidence tools if needed, then proceed_to_answer.",
    }, "\n"),
  }
  transition("gather", "after brief")
end

return M
