-- Call-hierarchy graph.
--
-- v1: LSP callHierarchy/outgoingCalls only.
--   file  --has-->  function  --calls-->  function
-- Files are containers in the HTML view; functions sit inside their file.
-- Viewer is a self-contained HTML page served over localhost (browser), not TTY.
local M = {}

local ARTIFACT_DIR = ".aicompanion/graphs"
local LSP_TIMEOUT_MS = 2500
local MAX_ROOT_FUNCS = 40
local MAX_CALLEES_PER = 30
local MAX_NODES = 120
local MAX_EDGES = 200
local DEFAULT_PORT = 8765

local FN_KINDS = {
  [vim.lsp.protocol.SymbolKind.Function] = true,
  [vim.lsp.protocol.SymbolKind.Method] = true,
  [vim.lsp.protocol.SymbolKind.Constructor] = true,
}

local state = {
  job = nil,
  port = DEFAULT_PORT,
  dir = nil,
}

-- ---------------------------------------------------------------------------
-- Paths
-- ---------------------------------------------------------------------------

local function project_root()
  local found = vim.fs.find(".git", { path = vim.fn.getcwd(), upward = true })[1]
  return found and vim.fs.dirname(found) or vim.fn.getcwd()
end

local function rel_path(abs)
  local root = vim.fs.normalize(project_root())
  local norm = vim.fs.normalize(abs or "")
  if norm:sub(1, #root) == root then
    return vim.fn.fnamemodify(norm:sub(#root + 2), ":.")
  end
  return vim.fn.fnamemodify(norm, ":.")
end

local function graphs_dir()
  local dir = project_root() .. "/" .. ARTIFACT_DIR
  vim.fn.mkdir(dir, "p")
  return dir
end

-- ---------------------------------------------------------------------------
-- Graph builders
-- ---------------------------------------------------------------------------

local function file_id(path)
  return "file:" .. path
end

local function fn_id(path, name, line)
  return ("fn:%s::%s@%d"):format(path, name, line or 0)
end

local function ensure_file(nodes, seen, path)
  local id = file_id(path)
  if not seen[id] then
    if vim.tbl_count(seen) >= MAX_NODES then
      return nil
    end
    seen[id] = true
    nodes[#nodes + 1] = {
      id = id,
      kind = "file",
      path = path,
      label = vim.fn.fnamemodify(path, ":t"),
    }
  end
  return id
end

local function ensure_fn(nodes, seen, path, name, line, detail)
  local id = fn_id(path, name, line)
  if not seen[id] then
    if vim.tbl_count(seen) >= MAX_NODES then
      return nil
    end
    seen[id] = true
    nodes[#nodes + 1] = {
      id = id,
      kind = "function",
      path = path,
      name = name,
      line = line or 0,
      detail = detail,
      label = name,
      parent = file_id(path),
    }
  end
  -- parent file must exist for the HTML compound graph
  ensure_file(nodes, seen, path)
  return id
end

local function add_edge(edges, seen_e, from, to, kind, via)
  if not from or not to or from == to then
    return
  end
  local key = from .. "|" .. to .. "|" .. kind .. "|" .. (via or "")
  if seen_e[key] then
    return
  end
  if #edges >= MAX_EDGES then
    return
  end
  seen_e[key] = true
  edges[#edges + 1] = { from = from, to = to, kind = kind, via = via }
end

-- ---------------------------------------------------------------------------
-- LSP: document symbols → prepareCallHierarchy → outgoingCalls
-- ---------------------------------------------------------------------------

local function has_method(bufnr, method)
  for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    if c:supports_method(method) then
      return true
    end
  end
  return false
end

local function flatten_functions(items, acc)
  acc = acc or {}
  for _, s in ipairs(items or {}) do
    if FN_KINDS[s.kind] and s.name and (s.selectionRange or s.range) then
      acc[#acc + 1] = s
    end
    if s.children then
      flatten_functions(s.children, acc)
    end
  end
  return acc
end

local function document_functions(bufnr)
  if not has_method(bufnr, "textDocument/documentSymbol") then
    return nil, "no documentSymbol support"
  end
  local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
  local results = vim.lsp.buf_request_sync(bufnr, "textDocument/documentSymbol", params, LSP_TIMEOUT_MS)
  if not results then
    return nil, "documentSymbol timed out"
  end
  local acc = {}
  for _, res in pairs(results) do
    if res.result then
      flatten_functions(res.result, acc)
    end
  end
  return acc
end

local function outgoing_for(bufnr, item)
  if not has_method(bufnr, "callHierarchy/outgoingCalls") then
    return {}
  end
  local results = vim.lsp.buf_request_sync(
    bufnr, "callHierarchy/outgoingCalls", { item = item }, LSP_TIMEOUT_MS)
  if not results then
    return {}
  end
  local out = {}
  for _, res in pairs(results) do
    for _, call in ipairs(res.result or {}) do
      out[#out + 1] = call
    end
  end
  return out
end

local function prepare_at(bufnr, line, character)
  if not has_method(bufnr, "textDocument/prepareCallHierarchy") then
    return nil
  end
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
    position = { line = line, character = character },
  }
  local results = vim.lsp.buf_request_sync(
    bufnr, "textDocument/prepareCallHierarchy", params, LSP_TIMEOUT_MS)
  if not results then
    return nil
  end
  for _, res in pairs(results) do
    if res.result and res.result[1] then
      return res.result[1]
    end
  end
  return nil
end

local function item_path(item)
  if not item or not item.uri then
    return nil
  end
  return rel_path(vim.uri_to_fname(item.uri))
end

local function item_line(item)
  local r = item and (item.selectionRange or item.range)
  return r and r.start and r.start.line or 0
end

--- Build a call-hierarchy graph rooted at `bufnr`.
--- @return table|nil graph, string|nil err
function M.build(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil, "invalid buffer"
  end
  local abs = vim.api.nvim_buf_get_name(bufnr)
  if abs == "" then
    return nil, "buffer has no file name"
  end
  if #vim.lsp.get_clients({ bufnr = bufnr }) == 0 then
    return nil, "no LSP client attached — open a file the language server knows"
  end
  if not has_method(bufnr, "textDocument/prepareCallHierarchy")
    or not has_method(bufnr, "callHierarchy/outgoingCalls") then
    return nil, "LSP server has no callHierarchy/outgoingCalls"
  end

  local root_path = rel_path(abs)
  local nodes, edges, seen_n, seen_e = {}, {}, {}, {}
  ensure_file(nodes, seen_n, root_path)

  local funcs, ferr = document_functions(bufnr)
  if not funcs then
    return nil, ferr
  end
  if #funcs > MAX_ROOT_FUNCS then
    funcs = vim.list_slice(funcs, 1, MAX_ROOT_FUNCS)
  end

  local prepared = 0
  local calls = 0

  for _, sym in ipairs(funcs) do
    local sel = sym.selectionRange or sym.range
    if sel and sel.start then
      local item = prepare_at(bufnr, sel.start.line, sel.start.character or 0)
      if item then
        prepared = prepared + 1
        local from_path = item_path(item) or root_path
        local from_id = ensure_fn(
          nodes, seen_n, from_path, item.name, item_line(item), item.detail)
        local file = ensure_file(nodes, seen_n, from_path)
        add_edge(edges, seen_e, file, from_id, "has")

        local outs = outgoing_for(bufnr, item)
        local n = 0
        for _, call in ipairs(outs) do
          n = n + 1
          if n > MAX_CALLEES_PER then
            break
          end
          local to = call.to
          if to and to.name then
            local to_path = item_path(to)
            if to_path then
              local to_id = ensure_fn(
                nodes, seen_n, to_path, to.name, item_line(to), to.detail)
              local to_file = ensure_file(nodes, seen_n, to_path)
              add_edge(edges, seen_e, to_file, to_id, "has")
              if from_id and to_id then
                add_edge(edges, seen_e, from_id, to_id, "calls")
                calls = calls + 1
              end
            end
          end
        end
      end
    end
  end

  return {
    id = "calls-" .. root_path:gsub("[^%w]+", "_"),
    root = root_path,
    source = "lsp:callHierarchy/outgoingCalls",
    nodes = nodes,
    edges = edges,
    stats = {
      root_functions = #funcs,
      prepared = prepared,
      call_edges = calls,
      nodes = #nodes,
      edges = #edges,
    },
  }
end

-- ---------------------------------------------------------------------------
-- Persist + Graphviz render
-- ---------------------------------------------------------------------------

local function dot_quote(s)
  return '"' .. tostring(s or ""):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

--- Graphviz DOT: files as clusters (containment = has), functions as ellipses,
--- solid edges = calls. `dot` does the layout — that's the quality win.
function M.to_dot(graph)
  local lines = {
    "digraph CallGraph {",
    "  rankdir=TB;",
    "  compound=true;",
    "  graph [fontname=\"Helvetica\", fontsize=12, bgcolor=\"#0f1115\",",
    "         fontcolor=\"#e8eaed\", pad=\"0.4\", nodesep=\"0.45\", ranksep=\"0.7\"];",
    "  node  [fontname=\"Helvetica\", fontsize=10, fontcolor=\"#e8eaed\"];",
    "  edge  [fontname=\"Helvetica\", fontsize=9];",
    "",
  }

  local by_file = {}
  for _, n in ipairs(graph.nodes or {}) do
    if n.kind == "function" then
      local path = n.path or "unknown"
      by_file[path] = by_file[path] or {}
      by_file[path][#by_file[path] + 1] = n
    elseif n.kind == "file" then
      by_file[n.path or n.label or "?"] = by_file[n.path or n.label or "?"] or {}
    end
  end

  local cluster_i = 0
  local paths = vim.tbl_keys(by_file)
  table.sort(paths)
  for _, path in ipairs(paths) do
    local fns = by_file[path]
    local label = vim.fn.fnamemodify(path, ":t")
    cluster_i = cluster_i + 1
    lines[#lines + 1] = ("  subgraph cluster_%d {"):format(cluster_i)
    lines[#lines + 1] = "    style=\"filled,rounded\";"
    lines[#lines + 1] = "    color=\"#c47d18\";"
    lines[#lines + 1] = "    fillcolor=\"#2a2114\";"
    lines[#lines + 1] = "    fontcolor=\"#f0a030\";"
    lines[#lines + 1] = "    label=" .. dot_quote("▲ " .. label) .. ";"
    -- Visible file marker inside the cluster (triangle).
    local fid = file_id(path)
    lines[#lines + 1] = ("    %s [label=%s, shape=triangle, style=filled,"
      .. " fillcolor=\"#f0a030\", fontcolor=\"#1a1208\", width=0.6, height=0.6];")
      :format(dot_quote(fid), dot_quote(label))
    for _, fn in ipairs(fns) do
      lines[#lines + 1] = ("    %s [label=%s, shape=ellipse, style=filled,"
        .. " fillcolor=\"#5b9cff\", fontcolor=\"#0b1220\"];")
        :format(dot_quote(fn.id), dot_quote(fn.label or fn.name))
      -- Ownership edge file → function (dashed), kept for explicit semantics.
      lines[#lines + 1] = ("    %s -> %s [style=dashed, color=\"#6b7280\","
        .. " arrowsize=0.7, constraint=false];")
        :format(dot_quote(fid), dot_quote(fn.id))
    end
    lines[#lines + 1] = "  }"
    lines[#lines + 1] = ""
  end

  for _, e in ipairs(graph.edges or {}) do
    if e.kind == "calls" then
      lines[#lines + 1] = ("  %s -> %s [color=\"#8bdc9a\", penwidth=1.6];")
        :format(dot_quote(e.from), dot_quote(e.to))
    end
  end

  lines[#lines + 1] = "}"
  lines[#lines + 1] = ""
  return table.concat(lines, "\n")
end

local function run_dot(dot_path, fmt, out_path)
  local res = vim.system({
    "dot", "-T" .. fmt, "-o", out_path, dot_path,
  }, { text = true }):wait()
  if res.code ~= 0 then
    return nil, vim.trim(res.stderr or res.stdout or ("dot exited " .. tostring(res.code)))
  end
  return out_path
end

--- HTML shell that embeds the Graphviz SVG (no Cytoscape).
function M.to_html(graph, svg_path)
  local root = graph.root or "?"
  local svg = ""
  if svg_path and vim.fn.filereadable(svg_path) == 1 then
    svg = table.concat(vim.fn.readfile(svg_path), "\n")
  end
  return table.concat({
    "<!DOCTYPE html>",
    "<html lang=\"en\">",
    "<head>",
    "<meta charset=\"utf-8\"/>",
    "<title>Call graph — " .. root .. "</title>",
    "<style>",
    "html,body{margin:0;background:#0f1115;color:#e8eaed;",
    "font-family:ui-sans-serif,system-ui,sans-serif}",
    "#meta{padding:10px 14px;border-bottom:1px solid #2a2f3a;font-size:13px}",
    "#meta code{color:#9db7ff}",
    "#view{padding:16px;overflow:auto}",
    "#view svg{max-width:100%;height:auto;display:block;margin:0 auto}",
    "</style>",
    "</head>",
    "<body>",
    "<div id=\"meta\">",
    "  <strong>root</strong> <code>" .. root .. "</code>",
    "  · " .. #(graph.nodes or {}) .. " nodes · " .. #(graph.edges or {}) .. " edges",
    "  · layout <code>graphviz/dot</code> · source <code>" .. (graph.source or "?") .. "</code>",
    "  <div style=\"margin-top:6px;opacity:.85\">",
    "    triangle = file · ellipse = function · dashed = has · solid = calls",
    "  </div>",
    "</div>",
    "<div id=\"view\">",
    svg,
    "</div>",
    "</body>",
    "</html>",
    "",
  }, "\n")
end

--- Write JSON + DOT + SVG + PNG + HTML. Requires `dot` on PATH.
--- @return table|nil paths, string|nil err
function M.save(graph)
  if vim.fn.executable("dot") ~= 1 then
    return nil, "graphviz `dot` not installed (apt install graphviz)"
  end

  local dir = graphs_dir()
  local stamp = os.date("%Y%m%d-%H%M%S")
  local base = ("%s-%s"):format(stamp, (graph.id or "graph"):gsub("[^%w%-_]+", "_"))
  local paths = {
    json = dir .. "/" .. base .. ".json",
    dot = dir .. "/" .. base .. ".dot",
    svg = dir .. "/" .. base .. ".svg",
    png = dir .. "/" .. base .. ".png",
    html = dir .. "/" .. base .. ".html",
  }

  vim.fn.writefile(vim.split(vim.json.encode(graph), "\n"), paths.json)
  vim.fn.writefile(vim.split(M.to_dot(graph), "\n"), paths.dot)

  local _, e1 = run_dot(paths.dot, "svg", paths.svg)
  if e1 then
    return nil, "dot svg: " .. e1
  end
  local _, e2 = run_dot(paths.dot, "png", paths.png)
  if e2 then
    return nil, "dot png: " .. e2
  end

  vim.fn.writefile(vim.split(M.to_html(graph, paths.svg), "\n"), paths.html)
  return paths
end

--- Show PNG in the terminal. User is responsible for Sixel/Kitty capability.
--- Tries chafa, then img2sixel; otherwise returns the file path + hint.
function M.render_terminal(png_path)
  if vim.fn.executable("chafa") == 1 then
    local res = vim.system({
      "chafa", "--size", "120x40", png_path,
    }, { text = true }):wait()
    if res.code == 0 and res.stdout and #res.stdout > 0 then
      return res.stdout, "chafa"
    end
  end
  if vim.fn.executable("img2sixel") == 1 then
    local res = vim.system({ "img2sixel", png_path }, { text = true }):wait()
    if res.code == 0 and res.stdout and #res.stdout > 0 then
      return res.stdout, "img2sixel"
    end
  end
  return nil, nil, png_path
end

-- ---------------------------------------------------------------------------
-- HTTP server + browser
-- ---------------------------------------------------------------------------

function M.stop_server()
  if state.job then
    pcall(function() state.job:kill(15) end)
    state.job = nil
  end
  -- Belt-and-braces: a previous session may have left a listener on our port.
  if state.port then
    pcall(function()
      vim.system({ "pkill", "-f", ("http.server %d"):format(state.port) }, { text = true }):wait()
    end)
  end
end

-- Always tear down the local viewer when Neovim exits (browser close does not).
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("ai-companion-graph", { clear = true }),
  desc = "Stop the AI graph HTML server",
  callback = function()
    M.stop_server()
  end,
})

local function pick_opener()
  if vim.fn.executable("wslview") == 1 then
    return { "wslview" }
  end
  if vim.fn.executable("xdg-open") == 1 then
    return { "xdg-open" }
  end
  if vim.fn.has("win32") == 1 or vim.fn.executable("cmd.exe") == 1 then
    return { "cmd.exe", "/c", "start", "" }
  end
  return nil
end

local function port_free(port)
  local res = vim.system({
    "python3", "-c",
    ("import socket;s=socket.socket();r=s.connect_ex(('127.0.0.1',%d));s.close();raise SystemExit(0 if r else 1)"):format(port),
  }, { text = true }):wait()
  return res.code == 0
end

function M.serve_and_open(html_path, opts)
  opts = opts or {}
  local dir = vim.fs.dirname(html_path)
  local name = vim.fs.basename(html_path)
  state.dir = dir
  M.stop_server()

  if vim.fn.executable("python3") ~= 1 then
    return nil, "python3 not available to serve the HTML"
  end

  local port = opts.port or state.port or DEFAULT_PORT
  if not port_free(port) then
    -- try a few alternatives rather than colliding with a zombie listener
    local found
    for p = port, port + 20 do
      if port_free(p) then
        found = p
        break
      end
    end
    if not found then
      return nil, "no free port near " .. tostring(port)
    end
    port = found
  end
  state.port = port

  state.job = vim.system({
    "python3", "-m", "http.server", tostring(port), "--bind", "127.0.0.1",
  }, { cwd = dir, text = true, detach = false })

  -- Confirm the listener is up before handing out the URL.
  local up = vim.wait(3000, function()
    return not port_free(port)
  end, 50)
  if not up then
    M.stop_server()
    return nil, "http.server failed to bind on port " .. tostring(port)
  end

  local url = ("http://127.0.0.1:%d/%s"):format(port, name)
  if opts.open ~= false then
    vim.defer_fn(function()
      local opener = pick_opener()
      if opener then
        local cmd = {}
        for _, p in ipairs(opener) do
          cmd[#cmd + 1] = p
        end
        cmd[#cmd + 1] = url
        vim.system(cmd, { detach = true })
      end
    end, 250)
  end

  return url
end

-- ---------------------------------------------------------------------------
-- Workflow entry
-- ---------------------------------------------------------------------------

local function summary_lines(graph, paths, extra)
  local s = graph.stats or {}
  local lines = {
    ("**Call graph** for `%s`"):format(graph.root),
    "",
    ("- root functions: %d (prepared %d)"):format(s.root_functions or 0, s.prepared or 0),
    ("- nodes: %d · edges: %d · call edges: %d"):format(
      s.nodes or 0, s.edges or 0, s.call_edges or 0),
    ("- layout: graphviz `dot`"),
    "",
    ("json: `%s`"):format(vim.fn.fnamemodify(paths.json, ":~:.")),
    ("dot:  `%s`"):format(vim.fn.fnamemodify(paths.dot, ":~:.")),
    ("svg:  `%s`"):format(vim.fn.fnamemodify(paths.svg, ":~:.")),
    ("png:  `%s`"):format(vim.fn.fnamemodify(paths.png, ":~:.")),
  }
  if extra and extra ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = extra
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "_triangle = file · ellipse = function · dashed = has · solid = calls_"
  return lines
end

--- @param arg string unused for now (root = current / visible buffer)
--- @param ctx table
--- @param cb fun(err, result)
function M.run(arg, ctx, cb)
  local write = require("qvd808.custom.ai.write")
  local buf = write.target() or vim.api.nvim_get_current_buf()

  ctx.on_step("graph", "collecting call hierarchy")
  local graph, err = M.build(buf)
  if not graph then
    return cb(err)
  end

  ctx.on_step("graph", "graphviz layout")
  local paths, serr = M.save(graph)
  if not paths then
    return cb(serr)
  end

  ctx.ask(
    "Graphviz layout ready. How do you want to view it?\n"
      .. "_Web = localhost HTML with SVG. Terminal = PNG via chafa/sixel — "
      .. "only pick this if you know your terminal can show images._",
    {
      { id = "web", label = "Web browser", hint = "serve Graphviz SVG over localhost" },
      { id = "terminal", label = "Terminal", hint = "print PNG (chafa / img2sixel) — you know your TTY" },
    },
    function(picked)
      local mode = picked and picked.id or "web"

      if mode == "terminal" then
        ctx.on_step("graph", "rendering in terminal")
        local art, tool, png = M.render_terminal(paths.png)
        local extra
        if art then
          extra = ("viewer: terminal (`%s`)\n\n```\n%s\n```"):format(tool, art)
        else
          extra = table.concat({
            "viewer: terminal (no chafa/img2sixel — showing path only)",
            "",
            ("PNG: `%s`"):format(vim.fn.fnamemodify(png or paths.png, ":~:.")),
            "",
            "Install `chafa` or `img2sixel`, or open the PNG yourself.",
            "Sixel tip (Windows Terminal): enable Sixel in profile settings.",
          }, "\n")
        end
        return cb(nil, {
          text = table.concat(summary_lines(graph, paths, extra), "\n"),
          meta = "graphviz · terminal",
        })
      end

      ctx.on_step("graph", "starting web server")
      local url, uerr = M.serve_and_open(paths.html)
      if not url then
        return cb(uerr or "could not start viewer", {
          text = table.concat(summary_lines(graph, paths,
            "open the HTML/SVG file manually"), "\n"),
        })
      end
      cb(nil, {
        text = table.concat(summary_lines(graph, paths, table.concat({
          ("viewer: %s"):format(url),
          "_:AIGraphStop to shut down the local server_",
        }, "\n")), "\n"),
        meta = ("graphviz · web · port %d"):format(state.port),
      })
    end)
end

return M
