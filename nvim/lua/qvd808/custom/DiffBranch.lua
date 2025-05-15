local state = {
  files_diff = {
    buf = -1,
    win = -1,
  },
  main_win = {
    buf = -1,
    win = -1,
    fugitive_on = false
  },
  branch = "main"
}

-- Check if file exists in current branch
local function file_exists_in_branch(branch, filepath)
  local cmd = string.format("git ls-tree --name-only %s %s", branch, filepath)
  local result = vim.fn.systemlist(cmd)
  return result[1] == filepath
end

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

  state.branch = branch

  -- Set the state for the current main window
  state.main_win.win = vim.api.nvim_get_current_win()
  state.main_win.buf = vim.api.nvim_get_current_buf()

  -- Create the window if it doesn't exist
  if not vim.api.nvim_win_is_valid(state.files_diff.win) then
    state.files_diff = create_window { buf = state.files_diff.buf }
  end

  -- List of file to iterate through
  local files = vim.fn.systemlist("git diff --name-only " .. branch .. " HEAD")

  if vim.v.shell_error ~= 0 then
    vim.notify("Failed to run git diff", vim.log.levels.ERROR)
    return
  end

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
end

vim.api.nvim_create_user_command("DiffBranch", diff_branch, {
  nargs = 1,             -- Require exactly one argument
  complete = "shellcmd", -- Optional: for shell-style completion
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
    if vim.api.nvim_buf_is_valid(state.main_win.buf) then
      state.main_win.buf = vim.api.nvim_create_buf(false, true)
    else
      vim.api.nvim_buf_set_lines(state.main_win.buf, 0, -1, false, {})
    end
    vim.api.nvim_set_current_win(state.main_win.win)

    -- Check if fugitive buffer is still on
    if state.main_win.fugitive_on then
      vim.cmd("q")
    end

    -- Open the file
    vim.cmd("edit " .. line)

    -- Check both branches
    local file_exists_in_current = file_exists_in_branch("HEAD", line)
    local file_exists_in_target = file_exists_in_branch(state.branch, line)


    if not file_exists_in_current then
      vim.notify("File does not exist in current branch: " .. line, vim.log.levels.ERROR)
      vim.api.nvim_set_current_win(state.files_diff.win)
      return
    end

    if not file_exists_in_target then
      vim.notify("File does not exist in branch '" .. state.branch .. "': " .. line, vim.log.levels.ERROR)
      vim.api.nvim_set_current_win(state.files_diff.win)
      return
    end

    -- Run Gdiffsplit with the provided branch
    -- vim.cmd("Gdiffsplit " .. state.branch .. ":" .. line)
    -- state.main_win.fugitive_on = true
    print(line)
    vim.api.nvim_set_current_win(state.files_diff.win)
  end
end
