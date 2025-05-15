local state = {
  files_diff = {
    buf = -1,
    win = -1,
  },
  main_win = {
    buf = -1,
    win = -1
  }
}

local function create_window(opts)
  opts = opts or {}

  -- Create or reuse the buffer
  local buf = nil
  if vim.api.nvim_buf_is_valid(opts.buf) then
    buf = opts.buf
  else
    buf = vim.api.nvim_create_buf(false, true) -- No file, scratch buffer
  end

  -- Open a horizontal split (use ':vsplit' for vertical)
  vim.cmd("vsplit")
  vim.cmd("vertical resize 30")

  -- Get the current window (the newly created split)
  local win = vim.api.nvim_get_current_win()

  -- Set the buffer to the window
  vim.api.nvim_win_set_buf(win, buf)

  -- Optional: set some window options
  vim.api.nvim_win_set_option(win, 'number', false)
  vim.api.nvim_win_set_option(win, 'relativenumber', false)

  return { buf = buf, win = win }
end

local diff_branch = function(opts)
  local branch = opts.args
  if branch == "" then
    vim.notify("Please provide a branch to compare with", vim.log.levels.ERROR)
    return
  end

  -- Set the state for the current main window
  state.main_win.win = vim.api.nvim_get_current_win()
  state.main_win.buf = vim.api.nvim_get_current_buf()

  -- Create the window if it doesn't exist
  if not vim.api.nvim_win_is_valid(state.files_diff.win) then
    state.files_diff = create_window { buf = state.files_diff.buf }
  end

  -- List of file to iterate through
  local lines = {
    "init.lua",
    "lua/qvd808/plugins/undotree.lua",
  }

  -- Set the lines in the buffer
  vim.api.nvim_buf_set_lines(state.files_diff.buf, 0, -1, false, lines)

  -- Press enter on the line trigger command
  vim.api.nvim_buf_set_keymap(state.files_diff.buf, 'n', '<CR>', [[:lua _G.on_diff_file_enter()<CR>]], {
    noremap = true,
    silent = true,
  })

  -- Define the global function to handle Enter
  _G.on_diff_file_enter = function()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line_num = cursor[1]
    local line = vim.api.nvim_buf_get_lines(0, line_num - 1, line_num, false)[1]

    if not line or line == "" then
      vim.notify("No file selected", vim.log.levels.WARN)
      return
    end

    -- Switch to the main window
    if vim.api.nvim_win_is_valid(state.main_win.win) then
      vim.api.nvim_set_current_win(state.main_win.win)

      -- Run Gdiffsplit with the selected file
      vim.cmd("Gdiffsplit " .. vim.fn.fnameescape(line))
    else
      vim.notify("Main window is no longer valid", vim.log.levels.ERROR)
    end
  end
end

vim.api.nvim_create_user_command("DiffBranch", diff_branch, {
  nargs = 1,             -- Require exactly one argument
  complete = "shellcmd", -- Optional: for shell-style completion
})
