local M = {}

-- Unknown environments deliberately retain text. Snacks performs the protocol
-- detection and handles SSH transfer; we never force terminal support.
function M.available(env, executable)
  env, executable = env or vim.env, executable or vim.fn.executable
  if env.NVIM_TERMINAL_GRAPHICS == "0" or env.ZELLIJ then return false end
  if executable("mmdc") ~= 1 or (executable("magick") ~= 1 and executable("convert") ~= 1) then return false end
  return env.KITTY_WINDOW_ID ~= nil or env.TERM == "xterm-kitty" or env.TERM_PROGRAM == "ghostty"
    or (env.TERM_PROGRAM or ""):lower() == "wezterm" or env.WEZTERM_PANE ~= nil
    or env.SNACKS_WEZTERM == "true"
    or env.TMUX ~= nil -- defer the outer terminal identification to Snacks
end

function M.configure_transport(env)
  env = env or vim.env
  -- Windows cannot open a WSL filename. Snacks' documented remote override
  -- transfers bytes through the graphics protocol instead. Do not fake SSH.
  if env.WSL_DISTRO_NAME or env.WSL_INTEROP then env.SNACKS_SSH = "true" end
end

function M.diagnostics()
  local messages = {}
  if vim.fn.executable("mmdc") ~= 1 then messages[#messages + 1] = "Missing mmdc: install @mermaid-js/mermaid-cli inside WSL." end
  if vim.fn.executable("magick") ~= 1 and vim.fn.executable("convert") ~= 1 then
    messages[#messages + 1] = "Missing ImageMagick: install imagemagick inside WSL (magick or convert)."
  end
  if vim.env.NVIM_TERMINAL_GRAPHICS == "0" then messages[#messages + 1] = "Disabled by NVIM_TERMINAL_GRAPHICS=0." end
  if #messages == 0 then
    messages[#messages + 1] = M.ready() and "Renderer selected. WezTerm uses cursor-hover previews, not inline images."
      or "Graphics unavailable: check outer terminal detection with :checkhealth snacks."
  end
  messages[#messages + 1] = "Windows WezTerm: enable_kitty_graphics = true; WSL uses byte transfer. See nvim/copilot-workflow/GRAPHICS.md."
  return table.concat(messages, "\n")
end

function M.ready()
  if not M.available() then return false end
  local ok, supported = pcall(function()
    return require("snacks.image").supports_terminal()
  end)
  return ok and supported == true
end

function M.attach(buf)
  if not M.available() or not vim.api.nvim_buf_is_valid(buf) then return false end
  local ok = pcall(function()
    vim.treesitter.language.register("markdown", { "codecompanion", "copilot_workflow" })
    -- Missing parsers must not interrupt chat or ticket controls.
    assert(vim.treesitter.get_parser(buf, "markdown"))
    require("snacks.image.doc").attach(buf)
  end)
  return ok
end

function M.diagram(state, selected)
  if not state then return {} end
  local unit = state.units[state.active + 1]
  for _, candidate in ipairs(state.units) do
    if candidate.id == selected then unit = candidate end
  end
  if not unit then return {} end
  local nodes = { planning = true, awaiting_plan = true, running = true,
    awaiting_review = true, accepted = true, paused = true, needs_decision = true }
  if not nodes[unit.status] then return {} end
  local target = unit.approved_attempt == unit.attempt and "running" or "planning"
  return {
    "", "Optional workflow graphic (text workflow above remains available)", "```mermaid",
    "flowchart TD", "planning -->|propose| awaiting_plan", "awaiting_plan -->|approve| running",
    "awaiting_plan -->|decline| planning", "running -->|checks and ready| awaiting_review",
    "awaiting_review -->|decline| planning", "awaiting_review -->|accept| accepted",
    "planning -->|question| needs_decision", "running -->|question| needs_decision",
    "needs_decision -->|answer| " .. target, "running -->|interrupt| paused",
    "paused -->|resume| running", "style " .. unit.status .. " fill:#285577,stroke:#88ccff,stroke-width:3px,color:#ffffff", "```",
  }
end

-- Snacks' non-placeholder path is used by WezTerm. Keep cursor movement and
-- placement in one UI write, and include screen coordinates in cached state.
function M.fix_placement()
  local placement = require("snacks.image.placement")
  if placement._qvd_coordinates then return end
  placement._qvd_coordinates = true
  local state = placement.state
  placement.state = function(self)
    local ret = state(self)
    if not require("snacks.image.terminal").env().placeholders then
      ret.screen_positions = {}
      for _, win in ipairs(ret.wins) do
        ret.screen_positions[win] = vim.api.nvim_win_get_position(win)
      end
    end
    return ret
  end
  placement.render_fallback = function(self, current)
    local terminal = require("snacks.image.terminal")
    if not self.opts.inline then
      vim.api.nvim_buf_clear_namespace(self.buf, placement.ns, 0, -1)
    end
    for _, win in ipairs(current.wins) do
      local border = setmetatable({ opts = vim.api.nvim_win_get_config(win) },
        { __index = Snacks.win }):border_size()
      local pos = vim.api.nvim_win_get_position(win)
      -- Window positions are zero-based, CUP coordinates are one-based.
      local cursor = string.format("\27[%d;%dH", pos[1] + border.top + 1, pos[2] + border.left + 1)
      local request = string.format("\27_Ga=p,i=%d,p=%d,C=1,c=%d,r=%d,q=2\27\\",
        self.img.id, self.id, current.loc.width, current.loc.height)
      terminal.write("\27" .. "7" .. cursor .. request .. "\27" .. "8")
    end
  end
end

function M.setup()
  local function preview_highlight()
    vim.api.nvim_set_hl(0, "TerminalGraphicsPreview", { bg = "#000000", fg = "#ffffff" })
  end
  preview_highlight()
  vim.api.nvim_create_user_command("TerminalGraphicsCheck", function()
    vim.notify(M.diagnostics(), vim.log.levels.INFO, { title = "Terminal graphics" })
  end, { force = true })
  local group = vim.api.nvim_create_augroup("terminal-graphics", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = preview_highlight })
  -- WezTerm placements are absolute: dismiss stale hover images on layout changes.
  vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized", "VimResized" }, {
    group = group,
    callback = function()
      local doc = package.loaded["snacks.image.doc"]
      if doc and doc.hover_close then doc.hover_close() end
    end,
  })
  vim.api.nvim_create_autocmd({ "FileType", "BufWinEnter" }, {
    group = group,
    callback = function(args)
      local ft = vim.bo[args.buf].filetype
      if ft == "codecompanion" or ft == "copilot_workflow" then
        vim.schedule(function() M.attach(args.buf) end)
      end
    end,
  })
end

return M
