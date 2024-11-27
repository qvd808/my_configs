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
-- Support function
function WrapLineInChar(char)
	-- Get the current line
	local line = vim.api.nvim_get_current_line():gsub("^%s*(.-)%s*$", "%1")

	-- Wrap the line in double quotes
	local wrapped_line = char .. line .. char

	-- Set the new line with quotes
	vim.api.nvim_set_current_line(wrapped_line)
end
-- Double quotes
vim.api.nvim_set_keymap(
	"n",
	'"iw',
	'ciw"<esc>pa"<esc>',
	{ noremap = true, silent = true, desc = "Word Surround Double Quotes" }
)
vim.api.nvim_set_keymap(
	"n",
	'""',
	[[:lua WrapLineInChar("\"")<CR>]],
	{ noremap = true, silent = true, desc = "Wrap line in given character" }
)
vim.api.nvim_set_keymap(
	"n",
	'"iW',
	'ciW"<esc>pa"<esc>',
	{ noremap = true, silent = true, desc = "Word Surround Double Quotes" }
)
-- Single quotes
vim.api.nvim_set_keymap(
	"n",
	"''",
	[[:lua WrapLineInChar("\'")<CR>]],
	{ noremap = true, silent = true, desc = "Wrap line in given character" }
)
vim.api.nvim_set_keymap(
	"n",
	"'iW",
	"ciW'<esc>pa'<esc>",
	{ noremap = true, silent = true, desc = "Word Surround Double Quotes" }
)
vim.api.nvim_set_keymap(
	"n",
	"'iw",
	"ciw'<esc>pa'<esc>",
	{ noremap = true, silent = true, desc = "Word Surround Single Quotes" }
)
-- Bracket quotes
vim.api.nvim_set_keymap(
	"n",
	"(iw",
	"ciw(<esc>pa)<esc>",
	{ noremap = true, silent = true, desc = "Word Surround bracket" }
)
vim.api.nvim_set_keymap(
	"n",
	")iw",
	"ciw(<esc>pa)<esc>",
	{ noremap = true, silent = true, desc = "Word Surround bracket" }
)
-- Square Bracket quotes
vim.api.nvim_set_keymap(
	"n",
	"[iw",
	"ciw[<esc>pa]<esc>",
	{ noremap = true, silent = true, desc = "Word Surround Square bracket" }
)
vim.api.nvim_set_keymap(
	"n",
	"]iw",
	"ciw[<esc>pa]<esc>",
	{ noremap = true, silent = true, desc = "Word Surround Square bracket" }
)
-- Curly Bracket quotes
vim.api.nvim_set_keymap(
	"n",
	"{iw",
	"ciw{<esc>pa}<esc>",
	{ noremap = true, silent = true, desc = "Word Surround Curly Bracket" }
)
vim.api.nvim_set_keymap(
	"n",
	"}iw",
	"ciw{<esc>pa}<esc>",
	{ noremap = true, silent = true, desc = "Word Surround Curly bracket" }
)
vim.api.nvim_set_keymap(
	"n",
	"'iw",
	"ciw'<esc>pa'<esc>",
	{ noremap = true, silent = true, desc = "Word Surround Single Quotes" }
)
-- Bracket quotes
vim.api.nvim_set_keymap(
	"n",
	"(iw",
	"ciw(<esc>pa)<esc>",
	{ noremap = true, silent = true, desc = "Word Surround bracket" }
)
vim.api.nvim_set_keymap(
	"n",
	")iw",
	"ciw(<esc>pa)<esc>",
	{ noremap = true, silent = true, desc = "Word Surround bracket" }
)
-- Square Bracket quotes
vim.api.nvim_set_keymap(
	"n",
	"[iw",
	"ciw[<esc>pa]<esc>",
	{ noremap = true, silent = true, desc = "Word Surround Square bracket" }
)
vim.api.nvim_set_keymap(
	"n",
	"]iw",
	"ciw[<esc>pa]<esc>",
	{ noremap = true, silent = true, desc = "Word Surround Square bracket" }
)
-- Curly Bracket quotes
vim.api.nvim_set_keymap(
	"n",
	"{iw",
	"ciw{<esc>pa}<esc>",
	{ noremap = true, silent = true, desc = "Word Surround Curly Bracket" }
)
vim.api.nvim_set_keymap(
	"n",
	"}iw",
	"ciw{<esc>pa}<esc>",
	{ noremap = true, silent = true, desc = "Word Surround Curly bracket" }
)
-- API for tmux split pane
-- Remap :vs to trigger tmux vertical split
vim.api.nvim_command('command! Vs lua TmuxSplit("v")')
vim.api.nvim_set_keymap('n', ':vs', ':lua TmuxSplit("v")<CR>', { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', ':hs', ':lua TmuxSplit("h")<CR>', { noremap = true, silent = true })

function TmuxSplit(type)
  -- Check if we're inside a tmux session
  if os.getenv('TMUX') then
    if type == 'v' then
      vim.fn.system('tmux split-window -h')
    elseif type == 'h' then
      vim.fn.system('tmux split-window -v')
    end
  else
    -- If not in tmux, fall back to normal Neovim split
    vim.cmd('vsp')
  end
end
