vim.g.mapleader = " "
vim.g.maplocalleader = " "

vim.opt.relativenumber = true
vim.opt.number = true
vim.opt.mouse = "a"
vim.opt.showmode = false

vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.autoread = true

-- search
vim.opt.hlsearch = true

-- clipboard and register
vim.opt.clipboard = "unnamedplus"
vim.opt.undofile = true

-- indentation
vim.opt.breakindent = true
vim.opt.autoindent = true
vim.opt.smartindent = false
vim.opt.cindent = true
vim.opt.list = true
vim.opt.lcs = { tab = "| ", trail = "_", nbsp = "␣" }
vim.opt.tabstop = 4
vim.opt.shiftwidth = 4
vim.opt.expandtab = false
vim.opt.paste = false
vim.opt.cindent = false
vim.opt.expandtab = false

-- decrease update time
vim.opt.updatetime = 250

-- Display which key popup sooner
vim.opt.timeoutlen = 300

-- Show which line your cursor is on
vim.opt.cursorline = true

-- Minimal number of screen lines to keep above and below the cursor
vim.opt.scrolloff = 20

-- Set highlight on search
vim.opt.hlsearch = true

-- Autocommand
local function remote_clipboard(reg_content, filename)
	-- Check if the file exist
	local file_exists = vim.fn.filereadable(filename) == 1
	if not file_exists then
		vim.api.nvim_err_writeln(filename .. " does not exist")
		return
	end

	--Write content to the file
	local file = io.open(filename, "w")
	if file then
		file:write(reg_content)
		file:close()
		vim.api.nvim_echo({{
			"Dumped to remote clipboard",
			"Normal"
		}}, true, {})
	end
end
vim.api.nvim_create_autocmd("TextYankPost", {
	desc = "Highlight when yanking text",
	group = vim.api.nvim_create_augroup("kickstart-highlight-yank", { clear = true }),
	callback = function()
		vim.highlight.on_yank()
		if vim.fn.exists('$SSH_CONNECTION') == 1 or vim.fn.exists('$SSH_TTY') == 1 then
			local content = vim.fn.getreg('"')
			local filename = vim.fn.expand("~/clip")
			remote_clipboard(content, filename)
		end
	end,
})

vim.api.nvim_create_autocmd({ "BufEnter", "CursorHold", "CursorHoldI", "FocusGained" }, {
	desc = "Reload buffer when files change",
	group = vim.api.nvim_create_augroup("reload-buffer-change", { clear = true }),
	callback = function()
		vim.api.nvim_command("checktime")
	end,
})

-- Usercommand
vim.api.nvim_create_user_command("Retab", function()
	vim.cmd("%retab!")
end, { nargs = 0 })

vim.api.nvim_create_user_command("Changetab", function()
	vim.cmd("%norm ^X")
end, { nargs = 0 })

-- Python style
vim.g.python_recommended_style = 0
vim.o.expandtab = false
