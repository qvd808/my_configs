-- Plan pipeline.
--
--   survey  ->  inspect  ->  plan
--   (LLM)       (no LLM)     (LLM)
--
-- Three nodes, two model calls, no tool loop. Each node receives only what it
-- needs: survey sees the file list, plan sees the digest survey asked for. No
-- conversation accumulates, so input stays flat instead of growing with every
-- observation the way a ReAct loop does.
--
-- The model cannot touch the tree at all here -- `inspect` is ordinary Lua,
-- not a tool it can call.
local provider = require("qvd808.custom.ai.provider")

local M = {}

local MAX_TREE         = 400
local MAX_PICK         = 12          -- files survey may request
-- The digest budget is the real ceiling; the per-file cap only stops one
-- enormous file from eating it. 400 was far too tight -- it truncated the very
-- file the plan was about, at 20% digest utilisation.
local READ_MAX_LINES   = 1200
local DIGEST_MAX_CHARS = 100 * 1024  -- bounds the plan node's input

-- ---------------------------------------------------------------------------
-- Contracts
-- ---------------------------------------------------------------------------
local SURVEY_SCHEMA = {
  type = "object",
  properties = {
    files = {
      type = "array",
      description = "Files worth reading before planning. At most " .. MAX_PICK .. ".",
      -- No line range here on purpose. Planning needs whole files; asking for
      -- ranges made the model guess 1-200 of a 655-line file and plan around
      -- code it never saw. `inspect` still supports from/to for workflows that
      -- genuinely target one function.
      items = {
        type = "object",
        properties = {
          path = { type = "string", description = "Project-relative path, from the list given" },
          why  = { type = "string", description = "What you expect to learn from it" },
        },
        required = { "path", "why" },
      },
    },
  },
  required = { "files" },
}

local PLAN_SCHEMA = {
  type = "object",
  properties = {
    goal = {
      type = "string",
      description = "One sentence restating what is being built",
    },
    approach = {
      type = "string",
      description = "Two or three sentences on the overall strategy",
    },
    todos = {
      type = "array",
      description = "Ordered list of concrete actions, one per file touched",
      items = {
        type = "object",
        properties = {
          id             = { type = "integer", description = "1-based position in the plan" },
          action         = { type = "string", enum = { "create", "modify", "delete", "test" },
                             description = "What happens to the file" },
          file           = { type = "string", description = "Project-relative path this step touches" },
          responsibility = { type = "string",
                             description = "What this file is responsible for once the step is done" },
          depends_on     = { type = "array", items = { type = "integer" },
                             description = "ids of steps that must complete first; empty if none" },
        },
        required = { "id", "action", "file", "responsibility" },
      },
    },
    risks = {
      type = "array",
      items = { type = "string" },
      description = "Things that could make this plan wrong",
    },
  },
  required = { "goal", "approach", "todos" },
}

local function tool(name, description, schema)
  return { type = "function", ["function"] = { name = name, description = description, parameters = schema } }
end

local SURVEY_TOOL = tool("emit_survey", "Emit the list of files to read before planning.", SURVEY_SCHEMA)
local PLAN_TOOL   = tool("emit_plan", "Emit the finished plan.", PLAN_SCHEMA)

-- Forcing the call is the equivalent of with_structured_output(): the model
-- cannot reply in prose, so there is no "it did not emit yet" branch to loop on.
local function forced(name)
  return { type = "function", ["function"] = { name = name } }
end

local SURVEY_SYSTEM = [[
Role: Senior engineer deciding what to read before planning a change.

You are given the project's file list and a goal. Pick only the files you must
actually see to write a correct plan: the ones you will change, plus any that
define an interface you depend on.

Each entry shows its line count, so you can judge how much you are asking for.
Files are read whole. Give the path only, without the "(N lines)" annotation.

Do not pick files out of curiosity. Fewer, well-chosen files produce a better
plan than a survey of the repository.

Call emit_survey exactly once.
]]

local PLAN_SYSTEM = [[
Role: Senior engineer producing an implementation plan.

You are given a goal and the contents of the files you asked for. Everything
you are going to see, you have already been given. Write the plan now.

Output Template (the emit_plan arguments):
1. goal:     one sentence restating what is being built
2. approach: two or three sentences on the overall strategy
3. todos:    ordered steps, one per file touched, each with
             - id             1-based position
             - action         create | modify | delete | test
             - file           project-relative path
             - responsibility what that file owns once the step is done
             - depends_on     ids that must land first (empty if none)
4. risks:    what could make this plan wrong

Rules:
- One todo per file. If a file needs two unrelated changes, that is two todos.
- responsibility describes the file's job, not the diff.
- At most 12 todos; combine trivia.
- If a file you needed was not provided, say so in risks rather than guessing.

Call emit_plan exactly once.
]]

-- ---------------------------------------------------------------------------
-- Filesystem. Ordinary Lua; none of this is exposed to the model.
-- ---------------------------------------------------------------------------
local function project_root()
  local found = vim.fs.find(".git", { path = vim.fn.getcwd(), upward = true })[1]
  return found and vim.fs.dirname(found) or vim.fn.getcwd()
end

local function resolve(path)
  local root = project_root()
  path = (path or ""):gsub("^@", "")
  -- the tree is shown as "path  (123 lines)"; models copy the annotation back
  path = path:gsub("%s*%(%d+ lines%)%s*$", "")
  path = vim.trim(path)
  local abs = vim.fs.normalize(vim.fn.fnamemodify(
    path:sub(1, 1) == "/" and path or (root .. "/" .. path), ":p"))
  local real = vim.uv.fs_realpath(abs) or abs
  if real:sub(1, #root) ~= root then   -- after realpath, so a symlink cannot escape
    return nil, "outside the project"
  end
  return real
end

local ARTIFACT_DIR = ".aicompanion"

-- --others --exclude-standard is the important part: plain `ls-files` lists
-- only *tracked* files, so a fresh project whose files are not yet git-added
-- looks completely empty and the planner invents paths.
local GIT_LS = "git ls-files --cached --others --exclude-standard"

-- Line counts matter: without them survey guesses ranges like 1-200 on a
-- 655-line file and the plan node silently never sees the rest.
local function line_counts(root)
  -- -r matters: without it xargs runs `wc -l` with no arguments on an empty
  -- repo, and wc then blocks reading stdin.
  local res = vim.system({ "sh", "-c",
    "cd " .. vim.fn.shellescape(root) .. " && " .. GIT_LS ..
    " -z | xargs -0 -r wc -l 2>/dev/null" },
    { text = true }):wait()
  local counts = {}
  if res.code ~= 0 then
    return counts
  end
  for line in (res.stdout or ""):gmatch("[^\n]+") do
    local n, name = line:match("^%s*(%d+)%s+(.+)$")
    if n and name and name ~= "total" then
      counts[name] = tonumber(n)
    end
  end
  return counts
end

local function project_files()
  local root = project_root()
  local res = vim.system({ "sh", "-c",
    "cd " .. vim.fn.shellescape(root) .. " && " .. GIT_LS }, { text = true }):wait()
  local files
  if res.code == 0 and res.stdout ~= "" then
    files = vim.split(vim.trim(res.stdout), "\n")
  else
    -- Not a git repo. globpath cannot see dotfiles at all (it would miss
    -- .gitignore, .editorconfig) and neither it nor vim.fs.dir knows what to
    -- ignore, so walk with vim.fs.dir and prune the usual suspects by hand.
    local PRUNE = { [".git"] = true, ["node_modules"] = true, [".venv"] = true,
                    ["venv"] = true, ["__pycache__"] = true, ["target"] = true,
                    ["dist"] = true, ["build"] = true, [".next"] = true,
                    [".cache"] = true, ["vendor"] = true }
    files = {}
    for name, type_ in vim.fs.dir(root, {
      depth = 8,
      skip = function(dirname) return not PRUNE[dirname] end,
    }) do
      if type_ == "file" then
        files[#files + 1] = name
      end
    end
  end
  -- our own artifacts are not part of the project being planned
  local kept = {}
  for _, f in ipairs(files) do
    if f ~= "" and f:sub(1, #ARTIFACT_DIR + 1) ~= ARTIFACT_DIR .. "/" then
      kept[#kept + 1] = f
    end
  end
  files = kept

  local truncated = #files > MAX_TREE
  if truncated then
    files = vim.list_slice(files, 1, MAX_TREE)
  end

  local counts = line_counts(root)
  local annotated = {}
  for i, f in ipairs(files) do
    annotated[i] = counts[f] and (f .. "  (" .. counts[f] .. " lines)") or f
  end
  return annotated, truncated
end

local function read_lines(path)
  -- buffer first: the only view that includes unsaved changes
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.fs.normalize(vim.api.nvim_buf_get_name(b)) == path then
      return vim.api.nvim_buf_get_lines(b, 0, -1, false)
    end
  end
  return vim.fn.readfile(path)
end

-- ---------------------------------------------------------------------------
-- Node 2: inspect. Deterministic, zero tokens, no model involvement.
-- ---------------------------------------------------------------------------
local function inspect(selection)
  local chunks = {}
  local stats = { files = 0, lines = 0, skipped = {}, partial = {} }
  local budget = DIGEST_MAX_CHARS

  for _, want in ipairs(selection) do
    if budget <= 0 then
      stats.skipped[#stats.skipped + 1] = want.path .. " (digest budget spent)"
    else
      local path, err = resolve(want.path)
      if not path then
        stats.skipped[#stats.skipped + 1] = want.path .. " (" .. err .. ")"
      elseif vim.fn.filereadable(path) ~= 1 then
        stats.skipped[#stats.skipped + 1] = want.path .. " (not readable)"
      else
        local lines = read_lines(path)
        local from = math.max(1, want.from or 1)
        local to = math.min(#lines, want.to or #lines)
        if to - from + 1 > READ_MAX_LINES then
          to = from + READ_MAX_LINES - 1
        end
        local body = table.concat(vim.list_slice(lines, from, to), "\n")
        if #body > budget then
          body = body:sub(1, budget)
        end
        budget = budget - #body
        stats.files = stats.files + 1
        stats.lines = stats.lines + (to - from + 1)
        local header = ("=== %s (lines %d-%d of %d) ==="):format(want.path, from, to, #lines)
        if to < #lines or from > 1 then
          header = header .. "\n[PARTIAL FILE - lines outside this range were not provided]"
          stats.partial[#stats.partial + 1] = want.path
        end
        chunks[#chunks + 1] = header .. "\n" .. body
      end
    end
  end

  return table.concat(chunks, "\n\n"), stats
end

-- ---------------------------------------------------------------------------
-- Validation. This enforces the contract; the schema only suggests it.
-- ---------------------------------------------------------------------------
local VALID_ACTIONS = { create = true, modify = true, delete = true, test = true }

function M.validate(plan)
  if type(plan) ~= "table" then
    return nil, "plan is not an object"
  end
  for _, f in ipairs({ "goal", "approach" }) do
    if type(plan[f]) ~= "string" or plan[f] == "" then
      return nil, "missing or empty field: " .. f
    end
  end
  if type(plan.todos) ~= "table" or #plan.todos == 0 then
    return nil, "todos must be a non-empty array"
  end

  local seen = {}
  for i, t in ipairs(plan.todos) do
    local where = "todos[" .. i .. "]"
    if type(t) ~= "table" then
      return nil, where .. " is not an object"
    end
    if type(t.id) ~= "number" then
      return nil, where .. ".id must be an integer"
    end
    if seen[t.id] then
      return nil, where .. ".id " .. t.id .. " is duplicated"
    end
    seen[t.id] = true
    if not VALID_ACTIONS[t.action] then
      return nil, where .. ".action must be create|modify|delete|test, got " .. tostring(t.action)
    end
    for _, f in ipairs({ "file", "responsibility" }) do
      if type(t[f]) ~= "string" or t[f] == "" then
        return nil, where .. "." .. f .. " missing"
      end
    end
  end

  for i, t in ipairs(plan.todos) do
    for _, dep in ipairs(t.depends_on or {}) do
      if not seen[dep] then
        return nil, "todos[" .. i .. "].depends_on references unknown id " .. tostring(dep)
      end
      if dep == t.id then
        return nil, "todos[" .. i .. "] depends on itself"
      end
    end
  end

  -- the dependency graph has to be acyclic or the apply state cannot order it
  local by_id, mark = {}, {}
  for _, t in ipairs(plan.todos) do
    by_id[t.id] = t
  end
  local function visit(id, trail)
    if mark[id] == "done" then
      return nil
    end
    if mark[id] == "open" then
      return "dependency cycle: " .. table.concat(trail, " -> ") .. " -> " .. id
    end
    mark[id] = "open"
    trail[#trail + 1] = id
    for _, dep in ipairs(by_id[id].depends_on or {}) do
      local cyc = visit(dep, trail)
      if cyc then
        return cyc
      end
    end
    trail[#trail] = nil
    mark[id] = "done"
    return nil
  end
  for _, t in ipairs(plan.todos) do
    local cyc = visit(t.id, {})
    if cyc then
      return nil, cyc
    end
  end

  return plan
end

local function validate_survey(args)
  if type(args) ~= "table" or type(args.files) ~= "table" then
    return nil, "files must be an array"
  end
  local out = {}
  for _, e in ipairs(args.files) do
    if type(e) == "table" and type(e.path) == "string" and e.path ~= "" then
      out[#out + 1] = e
    end
    if #out >= MAX_PICK then
      break
    end
  end
  if #out == 0 then
    return nil, "no usable file entries"
  end
  return out
end

-- ---------------------------------------------------------------------------
-- One structured call, with a single corrective retry. The retry re-sends the
-- validation error; it does not restart the thinking.
-- ---------------------------------------------------------------------------
local function structured_call(system, user, tool_def, name, validator, cb)
  local messages = {
    { role = "system", content = system },
    { role = "user", content = user },
  }
  local used = { in_tokens = 0, out_tokens = 0, ms = 0, calls = 0 }

  local function attempt(tries_left)
    provider.chat({
      messages = messages,
      tools = { tool_def },
      tool_choice = forced(name),
    }, function(err, choice, usage, ms)
      if err then
        return cb(err, nil, used)
      end
      used.calls = used.calls + 1
      used.in_tokens = used.in_tokens + (usage.prompt_tokens or 0)
      used.out_tokens = used.out_tokens + (usage.completion_tokens or 0)
      used.ms = used.ms + ms

      local msg = choice.message or {}
      local call = msg.tool_calls and msg.tool_calls[1]
      if not call then
        return cb("model did not call " .. name, nil, used)
      end

      local ok, args = pcall(vim.json.decode, call["function"].arguments or "{}")
      local value, verr
      if ok then
        value, verr = validator(args)
      else
        verr = "arguments were not valid JSON"
      end

      if value then
        return cb(nil, value, used)
      end
      if tries_left <= 0 then
        return cb(name .. " failed validation: " .. tostring(verr), nil, used)
      end

      messages[#messages + 1] = msg
      messages[#messages + 1] = {
        role = "tool", tool_call_id = call.id,
        content = "REJECTED: " .. tostring(verr) .. ". Call " .. name .. " again, corrected.",
      }
      attempt(tries_left - 1)
    end)
  end

  attempt(1)
end

-- ---------------------------------------------------------------------------
-- Pipeline
-- ---------------------------------------------------------------------------
--- @param goal string
--- @param opts table|nil  on_step(node, note)
--- @param cb fun(err: string|nil, plan: table|nil, stats: table|nil)
function M.run(goal, opts, cb)
  opts = opts or {}
  local note = opts.on_step or function() end
  local stats = { in_tokens = 0, out_tokens = 0, ms = 0, calls = 0, files = 0, lines = 0, skipped = {}, partial = {} }

  local function add(u)
    stats.in_tokens = stats.in_tokens + u.in_tokens
    stats.out_tokens = stats.out_tokens + u.out_tokens
    stats.ms = stats.ms + u.ms
    stats.calls = stats.calls + u.calls
  end

  local files, truncated = project_files()

  -- Greenfield: there is nothing to survey. Skipping the call also stops the
  -- model inventing a file to read and then planning around whatever the
  -- digest happened to contain.
  if #files == 0 then
    note("survey", "empty project, nothing to read")
    note("plan", "writing the plan")
    return structured_call(
      PLAN_SYSTEM,
      "Goal: " .. goal .. "\n\nThe project is EMPTY -- no files exist yet. "
        .. "Every todo will be a `create`. Do not reference existing files.",
      PLAN_TOOL, "emit_plan", M.validate,
      function(perr, plan, pusage)
        add(pusage)
        cb(perr, plan, stats)
      end)
  end

  local tree = table.concat(files, "\n")
  if truncated then
    tree = tree .. "\n... (truncated at " .. MAX_TREE .. " files)"
  end

  note("survey", "choosing files to read")
  structured_call(
    SURVEY_SYSTEM,
    "Project files:\n" .. tree .. "\n\nGoal: " .. goal,
    SURVEY_TOOL, "emit_survey", validate_survey,
    function(err, selection, usage)
      add(usage)
      if err then
        return cb(err, nil, stats)
      end

      local picked = {}
      for _, e in ipairs(selection) do
        picked[#picked + 1] = e.path
      end
      note("inspect", ("reading %d file(s): %s"):format(#selection, table.concat(picked, ", ")))

      local digest, istats = inspect(selection)
      stats.files, stats.lines = istats.files, istats.lines
      stats.skipped, stats.partial = istats.skipped, istats.partial

      note("plan", "writing the plan")
      -- A file that could not be read must be stated, not omitted. Silence
      -- reads as "nothing to say about it" and the model plans around a gap
      -- it does not know exists.
      local missing = ""
      if #istats.skipped > 0 then
        missing = "\n\nRequested but UNAVAILABLE (do not assume their contents):\n- "
          .. table.concat(istats.skipped, "\n- ")
      end
      structured_call(
        PLAN_SYSTEM,
        "Goal: " .. goal .. "\n\nFiles you asked for:\n\n" .. digest .. missing,
        PLAN_TOOL, "emit_plan", M.validate,
        function(perr, plan, pusage)
          add(pusage)
          if perr then
            return cb(perr, nil, stats)
          end
          cb(nil, plan, stats)
        end)
    end)
end

-- ---------------------------------------------------------------------------
-- Artifact
-- ---------------------------------------------------------------------------
local ACTION_MARK = { create = "+", modify = "~", delete = "-", test = "T" }

function M.to_markdown(plan)
  local out = { "**Goal** " .. plan.goal, "", plan.approach, "",
                "| # | | file | responsibility |", "|---|---|---|---|" }
  for _, t in ipairs(plan.todos) do
    local dep = ""
    if t.depends_on and #t.depends_on > 0 then
      dep = " _(after " .. table.concat(t.depends_on, ", ") .. ")_"
    end
    out[#out + 1] = ("| %d | %s | `%s` | %s%s |"):format(
      t.id, ACTION_MARK[t.action] or "?", t.file, t.responsibility, dep)
  end
  if plan.risks and #plan.risks > 0 then
    out[#out + 1] = ""
    out[#out + 1] = "**Risks**"
    for _, r in ipairs(plan.risks) do
      out[#out + 1] = "- " .. r
    end
  end
  return table.concat(out, "\n")
end

-- Persisted so a later state can be retried against this artifact instead of
-- re-running the pipeline. Written into the project being planned, under our
-- own directory -- `.pi` belongs to pi, we only borrowed the architecture.
M.PLANS_DIR = ".aicompanion/plans"

function M.save(plan)
  local dir = project_root() .. "/" .. M.PLANS_DIR
  vim.fn.mkdir(dir, "p")
  local path = ("%s/%s.json"):format(dir, os.date("%Y%m%d-%H%M%S"))
  vim.fn.writefile(vim.split(vim.json.encode(plan), "\n"), path)
  return path
end

M.PLAN_SCHEMA = PLAN_SCHEMA
M.SURVEY_SCHEMA = SURVEY_SCHEMA
return M
