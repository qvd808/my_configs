-- Clear highlight when exit search
vim.keymap.set("n", "<Esc>", "<cmd>nohlsearch<CR>")

-- Shift line around for indenting
local opt_shift = { noremap = true, silent = true }
vim.keymap.set("i", "<S-Tab>", "<cmd>:<<CR>", opt_shift)
vim.keymap.set("n", "<S-Tab>", "<<", opt_shift)
vim.keymap.set("n", "<Tab>", ">>", opt_shift)
vim.keymap.set("v", "<S-Tab>", "<gv", opt_shift)
vim.keymap.set("v", "<Tab>", ">gv", opt_shift)

-- Open file
vim.keymap.set("n", "<leader><leader>", vim.cmd.Ex)

-- Move to different window
vim.keymap.set("t", "<C-x>", "<C-\\><C-n>")
vim.keymap.set("n", "<C-j>", "<C-w><C-j>")
vim.keymap.set("n", "<C-k>", "<C-w><C-k>")
vim.keymap.set("n", "<C-l>", "<C-w><C-l>")
vim.keymap.set("n", "<C-h>", "<C-w><C-h>")

-- Diagnostic keymaps
vim.keymap.set("n", "[d", vim.diagnostic.goto_prev, { desc = "Go to previous [D]iagnostic message" })
vim.keymap.set("n", "]d", vim.diagnostic.goto_next, { desc = "Go to next [D]iagnostic message" })
vim.keymap.set("n", "<leader>e", vim.diagnostic.open_float, { desc = "Show diagnostic [E]rror message" })
vim.keymap.set("n", "[<leader>q", vim.diagnostic.goto_prev, { desc = "Open diagnostic [Q]uickfix list" })

-- Quickfix keymaps
vim.keymap.set("n", "<c-n>", ":cn<CR>")
vim.keymap.set("n", "<c-m>", ":cp<CR>")

-- Wrap word around
vim.api.nvim_set_keymap(
	"n",
	'wi"',
	'viw<esc>a"<esc>bi"<esc>',
	{ noremap = true, silent = true, desc = "Word Surround Quotes" }
)
vim.api.nvim_set_keymap(
	"n",
	"wi(",
	"viw<esc>a)<esc>bi(<esc>",
	{ noremap = true, silent = true, desc = "Word Surround Quotes" }
)
vim.api.nvim_set_keymap(
	"n",
	"wi)",
	"viw<esc>a)<esc>bi(<esc>",
	{ noremap = true, silent = true, desc = "Word Surround Quotes" }
)
