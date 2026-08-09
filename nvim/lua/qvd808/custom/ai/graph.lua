-- Call-hierarchy graph → Graphviz HTML viewer with ask-back to AI Companion.
--
-- Click a node in the browser → ask box beside it → Neovim packs LSP context
-- (and for file nodes, full related files) → Companion chats with the model.
local M = {}

local ARTIFACT_DIR = ".aicompanion/graphs"
local LSP_TIMEOUT_MS = 2500
local MAX_ROOT_FUNCS = 40
local MAX_CALLEES_PER = 30
local MAX_NODES = 120
local MAX_EDGES = 200
local DEFAULT_PORT = 8765
local SNIPPET_LINES = 80
local BODY_MAX_LINES = 220
local NEIGHBOR_SNIP_LINES = 18
local MAX_NEIGHBOR_SNIPS = 4
local FILE_MAX_CHARS = 80000
local MAX_RELATED_FILES = 12
local MAX_GLOBALS = 80
local TOTAL_FILE_CHARS = 220000
local HOVER_MAX_CHARS = 2500
local SIG_MAX_CHARS = 2000

local FN_KINDS = {
  [vim.lsp.protocol.SymbolKind.Function] = true,
  [vim.lsp.protocol.SymbolKind.Method] = true,
  [vim.lsp.protocol.SymbolKind.Constructor] = true,
}

local state = {
  job = nil,
  port = DEFAULT_PORT,
  dir = nil,
  pending_dir = nil,
  poll = nil,
  graph = nil,
  paths = nil,
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

local function abs_from_rel(path)
  if not path or path == "" then
    return nil
  end
  if path:sub(1, 1) == "/" then
    return path
  end
  return vim.fs.normalize(project_root() .. "/" .. path)
end

local function graphs_dir()
  local dir = project_root() .. "/" .. ARTIFACT_DIR
  vim.fn.mkdir(dir, "p")
  return dir
end

local function pending_dir()
  local dir = graphs_dir() .. "/pending"
  vim.fn.mkdir(dir, "p")
  return dir
end

local function server_script()
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) == "@" then
    local dir = vim.fs.dirname(src:sub(2))
    for _ = 1, 10 do
      local cand = dir .. "/scripts/graph_server.py"
      if vim.fn.filereadable(cand) == 1 then
        return cand
      end
      local parent = vim.fs.dirname(dir)
      if parent == dir then
        break
      end
      dir = parent
    end
  end
  local alt = vim.fn.expand("~/my_configs/scripts/graph_server.py")
  if vim.fn.filereadable(alt) == 1 then
    return alt
  end
  return alt
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
-- LSP helpers
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

local function incoming_for(bufnr, item)
  if not has_method(bufnr, "callHierarchy/incomingCalls") then
    return {}
  end
  local results = vim.lsp.buf_request_sync(
    bufnr, "callHierarchy/incomingCalls", { item = item }, LSP_TIMEOUT_MS)
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

local function buf_for_path(path)
  local abs = abs_from_rel(path)
  if not abs then
    return nil
  end
  local buf = vim.fn.bufnr(abs, false)
  if buf > 0 and vim.api.nvim_buf_is_loaded(buf) then
    return buf
  end
  if vim.fn.filereadable(abs) ~= 1 then
    return nil
  end
  buf = vim.fn.bufadd(abs)
  vim.fn.bufload(buf)
  return buf
end

--- When callHierarchy is missing (e.g. lua_ls), build edges by scanning each
--- function body for calls to other document-symbol names in this file, plus
--- `require("…")` targets resolved under the project.
local function build_from_symbols(bufnr, root_path, funcs)
  local nodes, edges, seen_n, seen_e = {}, {}, {}, {}
  ensure_file(nodes, seen_n, root_path)

  local by_name = {} -- bare name → list of { id, path, line, name }
  local calls = 0

  for _, sym in ipairs(funcs) do
    local sel = sym.selectionRange or sym.range
    local line = sel and sel.start and sel.start.line or 0
    local id = ensure_fn(nodes, seen_n, root_path, sym.name, line, sym.detail)
    local file = ensure_file(nodes, seen_n, root_path)
    add_edge(edges, seen_e, file, id, "has")
    if id then
      local bare = (sym.name or ""):match("([^%.]+)$") or sym.name
      by_name[bare] = by_name[bare] or {}
      by_name[bare][#by_name[bare] + 1] = {
        id = id,
        path = root_path,
        line = line,
        name = sym.name,
      }
    end
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)

  for _, sym in ipairs(funcs) do
    local range = sym.range or sym.selectionRange
    if not range or not range.start or not range["end"] then
      goto continue
    end
    local from_line = range.start.line
    local from_id = fn_id(root_path, sym.name, from_line)
    if not seen_n[from_id] then
      goto continue
    end

    local srow = range.start.line
    local erow = math.min(range["end"].line, line_count - 1)
    local body = table.concat(vim.api.nvim_buf_get_lines(bufnr, srow, erow + 1, false), "\n")
    local self_bare = (sym.name or ""):match("([^%.]+)$") or sym.name
    local n_edge = 0

    for bare, targets in pairs(by_name) do
      if bare ~= self_bare and #bare >= 2 then
        -- word-ish call: name(  or :name(  or .name(
        local pat = "[%.:]?" .. bare:gsub("(%W)", "%%%1") .. "%s*%("
        if body:find(pat) then
          for _, t in ipairs(targets) do
            if t.id ~= from_id then
              add_edge(edges, seen_e, from_id, t.id, "calls")
              calls = calls + 1
              n_edge = n_edge + 1
              if n_edge >= MAX_CALLEES_PER then
                break
              end
            end
          end
        end
      end
      if n_edge >= MAX_CALLEES_PER then
        break
      end
    end

    -- require("module.path") → file node if we can resolve it
    for mod in body:gmatch("require%s*%(%s*['\"]([^'\"]+)['\"]%s*%)") do
      local rel = mod:gsub("%.", "/") .. ".lua"
      local candidates = {
        rel,
        "lua/" .. rel,
        "nvim/lua/" .. rel,
      }
      for _, cand in ipairs(candidates) do
        local abs = abs_from_rel(cand)
        if abs and vim.fn.filereadable(abs) == 1 then
          local rpath = rel_path(abs)
          local fid = ensure_file(nodes, seen_n, rpath)
          if fid then
            add_edge(edges, seen_e, from_id, fid, "calls", "require")
            calls = calls + 1
          end
          break
        end
      end
    end

    ::continue::
  end

  return {
    id = "calls-" .. root_path:gsub("[^%w]+", "_"),
    root = root_path,
    source = "lsp:documentSymbol+scan (no callHierarchy)",
    nodes = nodes,
    edges = edges,
    stats = {
      root_functions = #funcs,
      prepared = #funcs,
      call_edges = calls,
      nodes = #nodes,
      edges = #edges,
    },
  }
end

local function build_from_call_hierarchy(bufnr, root_path, funcs)
  local nodes, edges, seen_n, seen_e = {}, {}, {}, {}
  ensure_file(nodes, seen_n, root_path)

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

--- Build a call graph rooted at `bufnr`.
--- Prefer LSP callHierarchy; fall back to documentSymbol + body scan (lua_ls).
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
  if not has_method(bufnr, "textDocument/documentSymbol") then
    return nil, "LSP has no documentSymbol (needed to list functions)"
  end

  local root_path = rel_path(abs)
  local funcs, ferr = document_functions(bufnr)
  if not funcs then
    return nil, ferr
  end
  if #funcs == 0 then
    return nil, "documentSymbol found no functions/methods in this buffer"
  end
  if #funcs > MAX_ROOT_FUNCS then
    funcs = vim.list_slice(funcs, 1, MAX_ROOT_FUNCS)
  end

  local use_hierarchy = has_method(bufnr, "textDocument/prepareCallHierarchy")
    and has_method(bufnr, "callHierarchy/outgoingCalls")

  if use_hierarchy then
    local graph = build_from_call_hierarchy(bufnr, root_path, funcs)
    -- Some servers advertise the method but never prepare (or return empty).
    if (graph.stats.prepared or 0) > 0 then
      return graph
    end
  end

  return build_from_symbols(bufnr, root_path, funcs)
end

-- ---------------------------------------------------------------------------
-- DOT / HTML
-- ---------------------------------------------------------------------------

local function dot_quote(s)
  return '"' .. tostring(s or ""):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

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
    local fid = file_id(path)
    -- Node name == graph id so SVG <title> maps back for clicks.
    lines[#lines + 1] = ("    %s [label=%s, shape=triangle, style=filled,"
      .. " fillcolor=\"#f0a030\", fontcolor=\"#1a1208\", width=0.6, height=0.6,"
      .. " tooltip=%s];")
      :format(dot_quote(fid), dot_quote(label), dot_quote(fid))
    for _, fn in ipairs(fns) do
      lines[#lines + 1] = ("    %s [label=%s, shape=ellipse, style=filled,"
        .. " fillcolor=\"#5b9cff\", fontcolor=\"#0b1220\", tooltip=%s];")
        :format(dot_quote(fn.id), dot_quote(fn.label or fn.name), dot_quote(fn.id))
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

local function html_escape(s)
  return tostring(s or "")
    :gsub("&", "&amp;")
    :gsub("<", "&lt;")
    :gsub(">", "&gt;")
    :gsub('"', "&quot;")
end

function M.to_html(graph, svg_path)
  local root = graph.root or "?"
  local svg = ""
  if svg_path and vim.fn.filereadable(svg_path) == 1 then
    svg = table.concat(vim.fn.readfile(svg_path), "\n")
  end
  local graph_json = vim.json.encode({
    root = graph.root,
    nodes = graph.nodes,
    edges = graph.edges,
    stats = graph.stats,
    source = graph.source,
  })

  local js = [[
(function () {
  const GRAPH = window.GRAPH || { nodes: [], edges: [] };
  const byId = {};
  (GRAPH.nodes || []).forEach(n => { byId[n.id] = n; });

  const panel = document.createElement("div");
  panel.id = "ask-panel";
  panel.innerHTML = [
    '<div class="ask-head"><strong id="ask-title">Ask</strong>',
    '<button type="button" id="ask-close" aria-label="Close">×</button></div>',
    '<div class="ask-meta" id="ask-meta"></div>',
    '<textarea id="ask-q" rows="4" placeholder="Ask about this node…"></textarea>',
    '<div class="ask-actions">',
    '<button type="button" id="ask-send">Ask AI</button>',
    '<span id="ask-status"></span>',
    '</div>'
  ].join("");
  document.body.appendChild(panel);

  let currentId = null;

  function hide() {
    panel.classList.remove("open");
    currentId = null;
  }

  function show(node, clientX, clientY) {
    currentId = node.id;
    document.getElementById("ask-title").textContent =
      node.kind === "file" ? ("File · " + (node.label || node.path))
        : ("Fn · " + (node.label || node.name || node.id));
    document.getElementById("ask-meta").textContent =
      (node.path || "") + (node.line != null ? (":" + (Number(node.line) + 1)) : "");
    document.getElementById("ask-q").value = "";
    document.getElementById("ask-status").textContent = "";
    panel.classList.add("open");
    const pad = 12;
    const w = panel.offsetWidth || 320;
    const h = panel.offsetHeight || 180;
    let left = clientX + pad;
    let top = clientY + pad;
    if (left + w > window.innerWidth - 8) left = Math.max(8, clientX - w - pad);
    if (top + h > window.innerHeight - 8) top = Math.max(8, clientY - h - pad);
    panel.style.left = left + "px";
    panel.style.top = top + "px";
    document.getElementById("ask-q").focus();
  }

  function nodeFromEvent(ev) {
    const g = ev.target.closest && ev.target.closest("g.node");
    if (!g) return null;
    const title = g.querySelector("title");
    const tip = g.querySelector("a[*|title], title");
    let id = title ? title.textContent.trim() : "";
    if (!id && g.getAttribute("id")) id = g.getAttribute("id");
    // Graphviz may wrap title text with quotes stripped already.
    if (id && byId[id]) return byId[id];
    // Fallback: match tooltip attribute if present on children.
    const t = g.querySelector("[title]");
    if (t) {
      const raw = (t.getAttribute("title") || "").trim();
      if (byId[raw]) return byId[raw];
    }
    void tip;
    return byId[id] || null;
  }

  document.getElementById("view").addEventListener("click", function (ev) {
    const node = nodeFromEvent(ev);
    if (!node) return;
    ev.preventDefault();
    ev.stopPropagation();
    show(node, ev.clientX, ev.clientY);
  });

  document.getElementById("ask-close").addEventListener("click", hide);

  document.getElementById("ask-send").addEventListener("click", async function () {
    const q = (document.getElementById("ask-q").value || "").trim();
    const status = document.getElementById("ask-status");
    if (!currentId || !q) {
      status.textContent = "Type a question first";
      return;
    }
    status.textContent = "Sending…";
    try {
      const res = await fetch("/api/ask", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ nodeId: currentId, question: q }),
      });
      const body = await res.json().catch(() => ({}));
      if (!res.ok) {
        status.textContent = "Error: " + (body.error || res.status);
        return;
      }
      status.textContent = "Queued — check AI Companion";
    } catch (err) {
      status.textContent = "Failed: " + err;
    }
  });
})();
]]

  return table.concat({
    "<!DOCTYPE html>",
    "<html lang=\"en\">",
    "<head>",
    "<meta charset=\"utf-8\"/>",
    "<title>Call graph — " .. html_escape(root) .. "</title>",
    "<style>",
    "html,body{margin:0;background:#0f1115;color:#e8eaed;",
    "font-family:ui-sans-serif,system-ui,sans-serif}",
    "#meta{padding:10px 14px;border-bottom:1px solid #2a2f3a;font-size:13px}",
    "#meta code{color:#9db7ff}",
    "#view{padding:16px;overflow:auto}",
    "#view svg{max-width:100%;height:auto;display:block;margin:0 auto}",
    "#view svg .node{cursor:pointer}",
    "#ask-panel{display:none;position:fixed;z-index:50;width:min(360px,calc(100vw - 24px));",
    "background:#1a1f2b;border:1px solid #3a4558;border-radius:10px;",
    "box-shadow:0 12px 40px rgba(0,0,0,.45);padding:10px 12px}",
    "#ask-panel.open{display:block}",
    "#ask-panel .ask-head{display:flex;align-items:center;justify-content:space-between;gap:8px}",
    "#ask-panel .ask-meta{font-size:12px;opacity:.75;margin:4px 0 8px;word-break:break-all}",
    "#ask-panel textarea{width:100%;box-sizing:border-box;resize:vertical;",
    "background:#0f1115;color:#e8eaed;border:1px solid #2a2f3a;border-radius:6px;",
    "padding:8px;font:inherit}",
    "#ask-panel .ask-actions{display:flex;align-items:center;gap:10px;margin-top:8px}",
    "#ask-panel button{background:#5b9cff;color:#0b1220;border:0;border-radius:6px;",
    "padding:6px 12px;font-weight:600;cursor:pointer}",
    "#ask-close{background:transparent;color:#e8eaed;font-size:18px;padding:0 6px}",
    "#ask-status{font-size:12px;opacity:.85}",
    "</style>",
    "</head>",
    "<body>",
    "<div id=\"meta\">",
    "  <strong>root</strong> <code>" .. html_escape(root) .. "</code>",
    "  · " .. #(graph.nodes or {}) .. " nodes · " .. #(graph.edges or {}) .. " edges",
    "  · layout <code>graphviz/dot</code> · source <code>" .. html_escape(graph.source or "?") .. "</code>",
    "  <div style=\"margin-top:6px;opacity:.85\">",
    "    click a node to ask the AI · triangle = file · ellipse = function",
    "  </div>",
    "</div>",
    "<div id=\"view\">",
    svg,
    "</div>",
    "<script>window.GRAPH = " .. graph_json .. ";</script>",
    "<script>",
    js,
    "</script>",
    "</body>",
    "</html>",
    "",
  }, "\n")
end

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

-- ---------------------------------------------------------------------------
-- Context packing for web asks
-- ---------------------------------------------------------------------------

local function find_node(graph, node_id)
  for _, n in ipairs((graph and graph.nodes) or {}) do
    if n.id == node_id then
      return n
    end
  end
  return nil
end

local function neighbors(graph, node_id)
  local callers, callees = {}, {}
  local by_id = {}
  for _, n in ipairs(graph.nodes or {}) do
    by_id[n.id] = n
  end
  for _, e in ipairs(graph.edges or {}) do
    if e.kind == "calls" then
      if e.to == node_id and by_id[e.from] then
        callers[#callers + 1] = by_id[e.from]
      elseif e.from == node_id and by_id[e.to] then
        callees[#callees + 1] = by_id[e.to]
      end
    end
  end
  return callers, callees
end

local function read_file_capped(path, max_chars)
  local abs = abs_from_rel(path)
  if not abs or vim.fn.filereadable(abs) ~= 1 then
    return nil, "unreadable"
  end
  local lines = vim.fn.readfile(abs)
  local text = table.concat(lines, "\n")
  if #text > max_chars then
    return text:sub(1, max_chars) .. ("\n\n… truncated at %d chars …\n"):format(max_chars), true
  end
  return text, false
end

local function snippet_for_fn(node)
  local buf = buf_for_path(node.path)
  if not buf then
    return nil
  end
  local start = math.max(0, (node.line or 0))
  local last = vim.api.nvim_buf_line_count(buf) - 1
  local finish = math.min(last, start + SNIPPET_LINES - 1)
  local lines = vim.api.nvim_buf_get_lines(buf, start, finish + 1, false)
  return table.concat(lines, "\n"), start + 1, finish + 1
end

--- Prefer the documentSymbol range for the focus name so we get the full body.
local function body_for_fn(node)
  local buf = buf_for_path(node.path)
  if not buf then
    return snippet_for_fn(node)
  end
  local funcs = document_functions(buf) or {}
  local match
  for _, s in ipairs(funcs) do
    if s.name == node.name or s.name == node.label then
      local line = s.selectionRange and s.selectionRange.start and s.selectionRange.start.line
        or (s.range and s.range.start and s.range.start.line)
      if line == nil or line == (node.line or 0) or not match then
        match = s
        if line == (node.line or 0) then
          break
        end
      end
    end
  end
  if match and match.range and match.range.start and match.range["end"] then
    local srow = match.range.start.line
    local erow = match.range["end"].line
    if erow - srow > BODY_MAX_LINES then
      erow = srow + BODY_MAX_LINES - 1
    end
    local last = vim.api.nvim_buf_line_count(buf) - 1
    erow = math.min(erow, last)
    local lines = vim.api.nvim_buf_get_lines(buf, srow, erow + 1, false)
    local detail = match.detail
    return table.concat(lines, "\n"), srow + 1, erow + 1, detail, match
  end
  local text, a, b = snippet_for_fn(node)
  return text, a, b, node.detail, nil
end

local function markdown_of_hover(result)
  if not result or not result.contents then
    return nil
  end
  local lines = vim.lsp.util.convert_input_to_markdown_lines(result.contents)
  local text = vim.trim(table.concat(lines, "\n"))
  if text == "" then
    return nil
  end
  if #text > HOVER_MAX_CHARS then
    text = text:sub(1, HOVER_MAX_CHARS) .. "\n…"
  end
  return text
end

local function hover_at_buf(buf, line, character)
  if not buf or not has_method(buf, "textDocument/hover") then
    return nil
  end
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(buf),
    position = { line = line, character = character or 0 },
  }
  local results = vim.lsp.buf_request_sync(buf, "textDocument/hover", params, LSP_TIMEOUT_MS)
  if not results then
    return nil
  end
  for _, res in pairs(results) do
    local md = markdown_of_hover(res.result)
    if md then
      return md
    end
  end
  return nil
end

local function signature_at_buf(buf, line, character)
  if not buf or not has_method(buf, "textDocument/signatureHelp") then
    return nil
  end
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(buf),
    position = { line = line, character = character or 0 },
  }
  local results = vim.lsp.buf_request_sync(buf, "textDocument/signatureHelp", params, LSP_TIMEOUT_MS)
  if not results then
    return nil
  end
  for _, res in pairs(results) do
    local sigs = res.result and res.result.signatures
    if sigs and #sigs > 0 then
      local chunks = {}
      for _, s in ipairs(sigs) do
        local label = s.label or ""
        local doc = s.documentation
        if type(doc) == "table" then
          doc = doc.value or vim.inspect(doc)
        end
        chunks[#chunks + 1] = label
        if doc and doc ~= "" then
          chunks[#chunks + 1] = tostring(doc)
        end
      end
      local text = vim.trim(table.concat(chunks, "\n"))
      if #text > SIG_MAX_CHARS then
        text = text:sub(1, SIG_MAX_CHARS) .. "\n…"
      end
      if text ~= "" then
        return text
      end
    end
  end
  return nil
end

local function neighbor_snip(n)
  local text = select(1, snippet_for_fn({
    path = n.path,
    line = n.line or 0,
    name = n.name,
  }))
  if not text or text == "" then
    return nil
  end
  local lines = vim.split(text, "\n")
  if #lines > NEIGHBOR_SNIP_LINES then
    local cut = {}
    for i = 1, NEIGHBOR_SNIP_LINES do
      cut[i] = lines[i]
    end
    cut[#cut + 1] = "…"
    text = table.concat(cut, "\n")
  end
  return text
end

local function scan_globals(text)
  local seen, out = {}, {}
  local function push(name)
    if not name or #name < 3 or seen[name] then
      return
    end
    seen[name] = true
    out[#out + 1] = name
  end
  for name in text:gmatch("(vim%.[%w_%.]+)") do
    push(name:gsub("%.$", ""))
  end
  for mod in text:gmatch("require%s*%(%s*['\"]([^'\"]+)['\"]%s*%)") do
    push("require(" .. mod .. ")")
  end
  for name in text:gmatch("(process%.[%w_%.]+)") do
    push(name:gsub("%.$", ""))
  end
  table.sort(out)
  if #out > MAX_GLOBALS then
    local trimmed = {}
    for i = 1, MAX_GLOBALS do
      trimmed[i] = out[i]
    end
    trimmed[#trimmed + 1] = ("… +%d more"):format(#out - MAX_GLOBALS)
    return trimmed
  end
  return out
end

local function list_file_functions(path)
  local buf = buf_for_path(path)
  if not buf then
    return {}
  end
  local funcs = document_functions(buf) or {}
  local out = {}
  for _, s in ipairs(funcs) do
    local line = s.selectionRange and s.selectionRange.start and s.selectionRange.start.line
      or (s.range and s.range.start and s.range.start.line)
      or 0
    out[#out + 1] = ("- `%s` @ %d"):format(s.name, line + 1)
  end
  return out
end

local function format_hierarchy_items(calls, direction)
  local lines = {}
  for _, call in ipairs(calls or {}) do
    local item = direction == "out" and call.to or call.from
    if item and item.name then
      local p = item_path(item) or "?"
      lines[#lines + 1] = ("- `%s` in `%s` @ %d"):format(item.name, p, item_line(item) + 1)
    end
  end
  if #lines == 0 then
    return { "_none_" }
  end
  return lines
end

local function prepare_for_node(node)
  local buf = buf_for_path(node.path)
  if not buf then
    return nil, nil, 0
  end
  local line = node.line or 0
  local text = vim.api.nvim_buf_get_lines(buf, line, line + 1, false)[1] or ""
  local col = 0
  if node.name and node.name ~= "" then
    local s = text:find(node.name, 1, true)
    if s then
      col = s - 1
    end
  end
  return buf, prepare_at(buf, line, col), col
end

local function pack_function(graph, node, question)
  local domain = require("qvd808.custom.ai.graph_fn_domain")
  local intents = domain.intents(question)

  local lines = {
    "# Graph ask (function) — domain brief",
    "",
    "## Question",
    question,
    "",
    "## Focus",
    ("- id: `%s`"):format(node.id),
    ("- name: `%s`"):format(node.name or node.label or "?"),
    ("- file: `%s`"):format(node.path or "?"),
    ("- line: %d"):format((node.line or 0) + 1),
    ("- intent tags: %s"):format(table.concat(intents, ", ")),
    "",
  }

  local body, body_from, body_to, detail, sym = body_for_fn(node)
  body = body or ""
  if detail and detail ~= "" then
    lines[#lines + 1] = "## Symbol detail (LSP documentSymbol)"
    lines[#lines + 1] = detail
    lines[#lines + 1] = ""
  end

  local buf, item, col = prepare_for_node(node)
  local hover = buf and hover_at_buf(buf, node.line or 0, col) or nil
  local sig = buf and signature_at_buf(buf, node.line or 0, col) or nil
  -- Signature help often wants to be inside the call; also try just after "(" on the def line.
  if not sig and buf then
    local def = vim.api.nvim_buf_get_lines(buf, node.line or 0, (node.line or 0) + 1, false)[1] or ""
    local paren = def:find("%(", 1, false)
    if paren then
      sig = signature_at_buf(buf, node.line or 0, paren)
    end
  end

  lines[#lines + 1] = "## Interface (params / returns / docs)"
  if hover then
    lines[#lines + 1] = "### Hover"
    lines[#lines + 1] = hover
    lines[#lines + 1] = ""
  end
  if sig then
    lines[#lines + 1] = "### SignatureHelp"
    lines[#lines + 1] = sig
    lines[#lines + 1] = ""
  end
  if not hover and not sig and not (detail and detail ~= "") then
    lines[#lines + 1] = "_LSP did not provide hover/signature; infer carefully from source below._"
    lines[#lines + 1] = ""
  end

  local callers, callees = neighbors(graph, node.id)
  lines[#lines + 1] = "## Architecture role"
  lines[#lines + 1] = ("- callers in graph: **%d**"):format(#callers)
  lines[#lines + 1] = ("- callees in graph: **%d**"):format(#callees)
  if #callers == 0 and #callees == 0 then
    lines[#lines + 1] = "- note: isolated in this graph slice (leaf or root of the scan)."
  elseif #callers > 0 and #callees == 0 then
    lines[#lines + 1] = "- note: likely a **leaf helper** (used by others, calls little in-graph)."
  elseif #callers == 0 and #callees > 0 then
    lines[#lines + 1] = "- note: likely an **orchestrator / entry** in this slice."
  else
    lines[#lines + 1] = "- note: **mid-layer** — both used and uses others."
  end
  lines[#lines + 1] = ""

  lines[#lines + 1] = "## Related (from call graph)"
  lines[#lines + 1] = "### Callers"
  if #callers == 0 then
    lines[#lines + 1] = "_none_"
  else
    for i, n in ipairs(callers) do
      lines[#lines + 1] = ("- `%s` in `%s` @ %d"):format(
        n.name or n.label, n.path or "?", (n.line or 0) + 1)
      if i <= MAX_NEIGHBOR_SNIPS then
        local sn = neighbor_snip(n)
        if sn then
          lines[#lines + 1] = "```"
          lines[#lines + 1] = sn
          lines[#lines + 1] = "```"
        end
      end
    end
  end
  lines[#lines + 1] = "### Callees"
  if #callees == 0 then
    lines[#lines + 1] = "_none_"
  else
    for i, n in ipairs(callees) do
      lines[#lines + 1] = ("- `%s` in `%s` @ %d"):format(
        n.name or n.label, n.path or "?", (n.line or 0) + 1)
      if i <= MAX_NEIGHBOR_SNIPS then
        local sn = neighbor_snip(n)
        if sn then
          lines[#lines + 1] = "```"
          lines[#lines + 1] = sn
          lines[#lines + 1] = "```"
        end
      end
    end
  end
  lines[#lines + 1] = ""

  if buf and item then
    lines[#lines + 1] = "## LSP call hierarchy"
    lines[#lines + 1] = "### Incoming"
    for _, l in ipairs(format_hierarchy_items(incoming_for(buf, item), "in")) do
      lines[#lines + 1] = l
    end
    lines[#lines + 1] = "### Outgoing"
    for _, l in ipairs(format_hierarchy_items(outgoing_for(buf, item), "out")) do
      lines[#lines + 1] = l
    end
    lines[#lines + 1] = ""
  else
    lines[#lines + 1] = "## LSP call hierarchy"
    lines[#lines + 1] = "_unavailable on this server (e.g. lua_ls); use Related + source._"
    lines[#lines + 1] = ""
  end

  lines[#lines + 1] = "## File-local functions (same file)"
  local locals = list_file_functions(node.path)
  if #locals == 0 then
    lines[#lines + 1] = "_none / no LSP symbols_"
  else
    for _, l in ipairs(locals) do
      lines[#lines + 1] = l
    end
  end
  lines[#lines + 1] = ""

  local globals = scan_globals(body)
  lines[#lines + 1] = "## Globals / external APIs used in focus body"
  if #globals == 0 then
    lines[#lines + 1] = "_none detected_"
  else
    for _, g in ipairs(globals) do
      lines[#lines + 1] = "- `" .. g .. "`"
    end
  end
  lines[#lines + 1] = ""

  lines[#lines + 1] = "## Focus source"
  if body_from and body_to then
    lines[#lines + 1] = ("```%s:%d-%d"):format(node.path or "?", body_from, body_to)
  else
    lines[#lines + 1] = "```"
  end
  lines[#lines + 1] = body
  lines[#lines + 1] = "```"
  if sym and sym.range and (sym.range["end"].line - sym.range.start.line + 1) > BODY_MAX_LINES then
    lines[#lines + 1] = ("_body truncated to %d lines_"):format(BODY_MAX_LINES)
  end
  lines[#lines + 1] = ""

  return table.concat(lines, "\n")
end

local function related_files_for(graph, file_path)
  local file_fns = {}
  for _, n in ipairs(graph.nodes or {}) do
    if n.kind == "function" and n.path == file_path then
      file_fns[n.id] = n
    end
  end
  local related, weight = {}, {}
  local function touch(path)
    if not path or path == file_path then
      return
    end
    weight[path] = (weight[path] or 0) + 1
    related[path] = true
  end
  for _, e in ipairs(graph.edges or {}) do
    if e.kind == "calls" then
      local from = find_node(graph, e.from)
      local to = find_node(graph, e.to)
      if from and to then
        if file_fns[from.id] then
          touch(to.path)
        end
        if file_fns[to.id] then
          touch(from.path)
        end
      end
    end
  end
  local list = vim.tbl_keys(related)
  table.sort(list, function(a, b)
    return (weight[a] or 0) > (weight[b] or 0)
  end)
  return list, weight
end

local function pack_file(graph, node, question)
  local path = node.path
  local lines = {
    "# Graph ask (file)",
    "",
    "## Question",
    question,
    "",
    "## Focus file",
    ("- id: `%s`"):format(node.id),
    ("- path: `%s`"):format(path or "?"),
    "",
    "## File-local functions",
  }
  local locals = list_file_functions(path)
  if #locals == 0 then
    lines[#lines + 1] = "_none / no LSP symbols_"
  else
    for _, l in ipairs(locals) do
      lines[#lines + 1] = l
    end
  end
  lines[#lines + 1] = ""

  local callers, callees = {}, {}
  for _, n in ipairs(graph.nodes or {}) do
    if n.kind == "function" and n.path == path then
      local c_in, c_out = neighbors(graph, n.id)
      for _, x in ipairs(c_in) do
        callers[#callers + 1] = x
      end
      for _, x in ipairs(c_out) do
        callees[#callees + 1] = x
      end
    end
  end
  lines[#lines + 1] = "## Call edges touching this file"
  lines[#lines + 1] = "### Incoming to functions in this file"
  if #callers == 0 then
    lines[#lines + 1] = "_none_"
  else
    local seen = {}
    for _, n in ipairs(callers) do
      local key = n.id
      if not seen[key] then
        seen[key] = true
        lines[#lines + 1] = ("- `%s` in `%s`"):format(n.name or n.label, n.path or "?")
      end
    end
  end
  lines[#lines + 1] = "### Outgoing from functions in this file"
  if #callees == 0 then
    lines[#lines + 1] = "_none_"
  else
    local seen = {}
    for _, n in ipairs(callees) do
      local key = n.id
      if not seen[key] then
        seen[key] = true
        lines[#lines + 1] = ("- `%s` in `%s`"):format(n.name or n.label, n.path or "?")
      end
    end
  end
  lines[#lines + 1] = ""

  local focus_text = select(1, read_file_capped(path, FILE_MAX_CHARS)) or ""
  local globals = scan_globals(focus_text)
  lines[#lines + 1] = "## Globals / external APIs used in focus file"
  if #globals == 0 then
    lines[#lines + 1] = "_none detected_"
  else
    for _, g in ipairs(globals) do
      lines[#lines + 1] = "- `" .. g .. "`"
    end
  end
  lines[#lines + 1] = ""

  local budget = TOTAL_FILE_CHARS
  lines[#lines + 1] = "## Focus file contents"
  lines[#lines + 1] = ("```path=%s"):format(path)
  local chunk = focus_text
  if #chunk > budget then
    chunk = chunk:sub(1, budget) .. "\n… truncated …\n"
  end
  lines[#lines + 1] = chunk
  lines[#lines + 1] = "```"
  budget = budget - #chunk
  lines[#lines + 1] = ""

  local related = select(1, related_files_for(graph, path))
  lines[#lines + 1] = "## Related files (full contents)"
  if #related == 0 then
    lines[#lines + 1] = "_no related files in graph_"
  end
  local omitted = {}
  local included = 0
  for _, rpath in ipairs(related) do
    if included >= MAX_RELATED_FILES or budget < 2000 then
      omitted[#omitted + 1] = rpath
    else
      local body = select(1, read_file_capped(rpath, math.min(FILE_MAX_CHARS, budget))) or ""
      lines[#lines + 1] = ("### `%s`"):format(rpath)
      local rlocals = list_file_functions(rpath)
      if #rlocals > 0 then
        lines[#lines + 1] = "Symbols:"
        for _, l in ipairs(rlocals) do
          lines[#lines + 1] = l
        end
      end
      lines[#lines + 1] = ("```path=%s"):format(rpath)
      lines[#lines + 1] = body
      lines[#lines + 1] = "```"
      lines[#lines + 1] = ""
      budget = budget - #body
      included = included + 1
    end
  end
  if #omitted > 0 then
    lines[#lines + 1] = "### Omitted related files (budget)"
    for _, p in ipairs(omitted) do
      lines[#lines + 1] = "- `" .. p .. "`"
    end
    lines[#lines + 1] = ""
  end

  return table.concat(lines, "\n")
end

function M.pack_ask(graph, node_id, question)
  local node = find_node(graph, node_id)
  if not node then
    return nil, "unknown node: " .. tostring(node_id)
  end
  if node.kind == "file" then
    return pack_file(graph, node, question)
  end
  return pack_function(graph, node, question)
end

function M.handle_web_ask(req)
  if not state.graph then
    return nil, "no active graph session"
  end
  local node_id = req.nodeId or req.node_id
  local question = req.question or ""
  local node = find_node(state.graph, node_id)
  if not node then
    return nil, "unknown node: " .. tostring(node_id)
  end

  local ok, companion = pcall(require, "qvd808.custom.AICompanion")
  if not ok then
    return nil, "AICompanion unavailable"
  end

  local display = ("[graph] %s"):format(question)

  -- Function nodes: rich brief + bounded tool loop.
  if node.kind == "function" then
    local brief, berr = M.pack_ask(state.graph, node_id, question)
    if not brief then
      return nil, berr
    end
    if not companion.ask_fn_agent then
      return nil, "AICompanion.ask_fn_agent unavailable"
    end
    companion.ask_fn_agent(display, {
      graph = state.graph,
      node = node,
      question = question,
      brief = brief,
    })
    return true
  end

  -- File nodes: one-shot packed context (full files).
  local packed, err = M.pack_ask(state.graph, node_id, question)
  if not packed then
    return nil, err
  end
  if not companion.ask_with_context then
    return nil, "AICompanion.ask_with_context unavailable"
  end
  companion.ask_with_context(display, packed)
  return true
end

-- ---------------------------------------------------------------------------
-- HTTP server + pending poller
-- ---------------------------------------------------------------------------

local function stop_poller()
  if state.poll then
    pcall(function()
      state.poll:stop()
      state.poll:close()
    end)
    state.poll = nil
  end
end

local function process_pending()
  local dir = state.pending_dir
  if not dir then
    return
  end
  local files = vim.fn.glob(dir .. "/ask-*.json", false, true)
  table.sort(files)
  for _, path in ipairs(files) do
    local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
    pcall(vim.fn.delete, path)
    if ok and type(decoded) == "table" and decoded.question then
      local _, err = M.handle_web_ask(decoded)
      if err then
        vim.notify("graph ask: " .. err, vim.log.levels.WARN)
      end
      return -- one per tick
    end
  end
end

local function start_poller()
  stop_poller()
  state.poll = vim.uv.new_timer()
  state.poll:start(250, 250, function()
    vim.schedule(process_pending)
  end)
end

function M.stop_server()
  stop_poller()
  if state.job then
    pcall(function() state.job:kill(15) end)
    state.job = nil
  end
  if state.port then
    pcall(function()
      vim.system({ "pkill", "-f", ("graph_server.py %d"):format(state.port) }, { text = true }):wait()
    end)
  end
end

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
  state.pending_dir = pending_dir()
  M.stop_server()

  if vim.fn.executable("python3") ~= 1 then
    return nil, "python3 not available to serve the HTML"
  end
  local script = server_script()
  if vim.fn.filereadable(script) ~= 1 then
    return nil, "missing graph_server.py at " .. script
  end

  local port = opts.port or state.port or DEFAULT_PORT
  if not port_free(port) then
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
    "python3", script, tostring(port), dir, state.pending_dir,
  }, { text = true, detach = false })

  local up = vim.wait(3000, function()
    return not port_free(port)
  end, 50)
  if not up then
    M.stop_server()
    return nil, "graph_server failed to bind on port " .. tostring(port)
  end

  start_poller()

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
    ("- viewer: click a node to ask AI Companion"),
    "",
    ("json: `%s`"):format(vim.fn.fnamemodify(paths.json, ":~:.")),
    ("html: `%s`"):format(vim.fn.fnamemodify(paths.html, ":~:.")),
  }
  if extra and extra ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = extra
  end
  return lines
end

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

  state.graph = graph
  state.paths = paths

  ctx.on_step("graph", "starting web server")
  local url, uerr = M.serve_and_open(paths.html)
  if not url then
    return cb(uerr or "could not start viewer", {
      text = table.concat(summary_lines(graph, paths, "open the HTML file manually"), "\n"),
    })
  end
  cb(nil, {
    text = table.concat(summary_lines(graph, paths, table.concat({
      ("viewer: %s"):format(url),
      "Click a node → ask box → AI Companion gets packed LSP context.",
      "_:AIGraphStop to shut down the local server_",
    }, "\n")), "\n"),
    meta = ("graphviz · web · port %d"):format(state.port),
  })
end

return M
