vim.opt.runtimepath:append(vim.fn.getcwd() .. "/nvim")
local graphics = require("qvd808.custom.terminal_graphics")
local yes = function() return 1 end
assert(not graphics.available({}, yes))
assert(graphics.available({ TERM_PROGRAM = "WezTerm" }, yes))
assert(graphics.available({ TERM_PROGRAM = "tmux", TMUX = "1", WSL_DISTRO_NAME = "Ubuntu" }, yes))
assert(graphics.available({ WEZTERM_PANE = "0" }, yes))
assert(graphics.available({ SNACKS_WEZTERM = "true" }, yes))
assert(graphics.available({ TERM_PROGRAM = "WezTerm" }, function(name)
  return (name == "mmdc" or name == "convert") and 1 or 0
end))
assert(not graphics.available({ TERM_PROGRAM = "WezTerm" }, function(name)
  return name == "mmdc" and 1 or 0
end))
local wsl = { WSL_DISTRO_NAME = "Ubuntu", SNACKS_SSH = "false" }
graphics.configure_transport(wsl)
assert(wsl.SNACKS_SSH == "true", "WSL must transmit image bytes to Windows")
local local_env = {}
graphics.configure_transport(local_env)
assert(local_env.SNACKS_SSH == nil)
assert(not graphics.available({ TERM_PROGRAM = "ghostty", ZELLIJ = "1" }, yes))
assert(not graphics.available({ TERM = "xterm-kitty", NVIM_TERMINAL_GRAPHICS = "0" }, yes))
assert(not graphics.available({ TERM = "xterm-kitty" }, function() return 0 end))
assert(graphics.available({ TERM_PROGRAM = "ghostty", TMUX = "session", SSH_CONNECTION = "remote" }, yes))
assert(graphics.available({ KITTY_WINDOW_ID = "1" }, yes))
local state = { active = 1, units = {
  { id = "u1", status = "needs_decision", attempt = 2, approved_attempt = 1 },
  { id = "u2", status = "running", attempt = 1, approved_attempt = 1 },
} }
local older = table.concat(graphics.diagram(state, "u1"), "\n")
assert(older:find("style needs_decision", 1, true))
assert(older:find("needs_decision -->|answer| planning", 1, true))
local current = table.concat(graphics.diagram(state), "\n")
assert(current:find("style running", 1, true))
assert(current:find("needs_decision -->|answer| running", 1, true))
assert(#graphics.diagram(nil) == 0)
local available = graphics.available
graphics.available = function() return true end
package.loaded["snacks.image"] = { supports_terminal = function() error("renderer failed") end }
assert(not graphics.ready())
package.loaded["snacks.image"] = { supports_terminal = function() return false end }
assert(not graphics.ready())
package.loaded["snacks.image"] = { supports_terminal = function() return true end }
assert(graphics.ready())
local buf = vim.api.nvim_create_buf(false, true)
assert(not graphics.attach(-1))
-- With no Markdown parser/renderer installed, attachment safely fails.
assert(not graphics.attach(buf))
local parser = vim.treesitter.get_parser
vim.treesitter.get_parser = function() return {} end
local attached = {}
package.loaded["snacks.image.doc"] = { attach = function(b) attached[#attached + 1] = b end }
graphics.setup()
assert(vim.fn.exists(":TerminalGraphicsCheck") == 2)
local executable = vim.fn.executable
vim.fn.executable = function() return 0 end
assert(graphics.diagnostics():find("Missing mmdc", 1, true))
assert(graphics.diagnostics():find("Missing ImageMagick", 1, true))
vim.fn.executable = executable
vim.bo[buf].filetype = "codecompanion"
vim.wait(100, function() return #attached > 0 end)
assert(attached[1] == buf, "Chat FileType must attach the document renderer")
local view = require("qvd808.custom.copilot_workflow_view")
view.toggle(function() return state end, {})
local workflow_buf = vim.api.nvim_get_current_buf()
local rendered = table.concat(vim.api.nvim_buf_get_lines(workflow_buf, 0, -1, false), "\n")
assert(rendered:find("```mermaid", 1, true), "Supported workflow must include a graphic")
assert(rendered:find("style running", 1, true))
view.toggle()
package.loaded["snacks.image"] = { supports_terminal = function() error("failure") end }
view.toggle(function() return state end, {})
rendered = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false), "\n")
assert(not rendered:find("```mermaid", 1, true), "Failed renderer must retain the text view")
assert(rendered:find("Working", 1, true) or rendered:find("running", 1, true))
view.toggle()
vim.treesitter.get_parser = parser
graphics.available = available
vim.api.nvim_buf_delete(buf, { force = true })
print("Graphics capability, fallback and selected-state checks passed")
local writes = {}
package.loaded['snacks.image.terminal'] = { env = function() return { placeholders = false } end, write = function(s) writes[#writes+1] = s end }
local placement = { ns = vim.api.nvim_create_namespace('test'), state = function() return { wins = { vim.api.nvim_get_current_win() } } end }
package.loaded['snacks.image.placement'] = placement
_G.Snacks = { win = { border_size = function() return { top = 1, left = 1 } end } }
graphics.fix_placement()
local win = vim.api.nvim_get_current_win()
local pos = vim.api.nvim_win_get_position(win)
assert(vim.deep_equal(placement.state({}).screen_positions[win], pos))
placement.render_fallback({ buf = vim.api.nvim_get_current_buf(), opts = {}, img = { id = 42 }, id = 7 }, { wins = {win}, loc = { width = 8, height = 4 } })
assert(#writes == 1)
assert(writes[1]:find(string.format('\27[%d;%dH', pos[1]+2, pos[2]+2), 1, true))
assert(writes[1]:sub(-2) == '\27' .. '8')
local spec = dofile('nvim/lua/qvd808/plugins/terminal_graphics.lua')[1]
local options = spec.opts().image
assert(options.doc.wo.winblend == 0, 'Hover must be opaque')
assert(options.doc.wo.winhighlight:find('NormalFloat:TerminalGraphicsPreview', 1, true))
local args = options.convert.mermaid
local background, theme
for i, arg in ipairs(args) do
  if arg == '-b' then background = args[i+1] end
  if arg == '-t' then theme = args[i+1] end
end
assert(background == '#000000' and theme == 'dark', 'Mermaid must render legibly on black')
assert(options.cache:find('image-opaque-black-v1', 1, true), 'Do not reuse transparent cache')
graphics.setup()
assert(vim.api.nvim_get_hl(0, { name = 'TerminalGraphicsPreview' }).bg == 0)
vim.api.nvim_set_hl(0, 'TerminalGraphicsPreview', { bg = '#ffffff' })
vim.api.nvim_exec_autocmds('ColorScheme', {})
assert(vim.api.nvim_get_hl(0, { name = 'TerminalGraphicsPreview' }).bg == 0)
