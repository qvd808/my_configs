return {
  "tpope/vim-fugitive",
  config = function()
    -- Define DiffBranch command in Lua
    vim.api.nvim_create_user_command("DiffBranch", function(opts)
      local branch = opts.args
      if branch == "" then
        vim.notify("Please provide a branch to compare with", vim.log.levels.ERROR)
        return
      end

      -- Step 1: Open file list on the left (30%)
      vim.cmd("vsplit | vertical resize 30")
      local list_buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_win_set_buf(0, list_buf)

      -- Get list of changed files using systemlist
      local files = vim.fn.systemlist("git diff --name-only " .. branch .. " HEAD")
      if vim.v.shell_error ~= 0 then
        vim.notify("Failed to run git diff", vim.log.levels.ERROR)
        return
      end

      if #files == 0 then
        vim.notify("No differences with " .. branch, vim.log.levels.INFO)
        return
      end

      -- Step 2: Populate the file list buffer
      vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, files)
      vim.api.nvim_buf_set_name(list_buf, "DiffFiles: " .. branch)
      local bufnr = list_buf
      vim.bo[bufnr].modifiable = false
      vim.bo[bufnr].filetype = "diff-files"

      -- Step 3: Create main buffer for viewing diffs
      vim.cmd("wincmd l")
      local diff_buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_win_set_buf(0, diff_buf)
      vim.api.nvim_buf_set_name(diff_buf, "Diff View")

      -- Step 4: Set up key mappings
      local current_diff_buf = nil
      vim.keymap.set('n', '<CR>', function()
        local line = vim.api.nvim_get_current_line()
        if line ~= "" then
          vim.cmd("wincmd l")

          -- Clean existing diff buffers
          if current_diff_buf and vim.api.nvim_buf_is_valid(current_diff_buf) then
            local wins = vim.fn.win_findbuf(current_diff_buf)
            for _, win_id in ipairs(wins) do
              if vim.api.nvim_win_is_valid(win_id) then
                local buf_id = vim.api.nvim_win_get_buf(win_id)
                vim.api.nvim_win_close(win_id, true)
                if #vim.fn.win_findbuf(buf_id) == 0 then
                  pcall(vim.api.nvim_buf_delete, buf_id, { force = true })
                end
              end
            end
          end

          vim.cmd("Gvdiffsplit " .. branch .. ":" .. line)
          current_diff_buf = vim.api.nvim_get_current_buf()
        end
      end, { buffer = list_buf, desc = "Show diff for selected file" })

      vim.keymap.set('n', 'q', function()
        -- Close all fugitive buffers
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_is_valid(buf) then
            local buf_name = vim.api.nvim_buf_get_name(buf)
            if buf_name:match("fugitive://") and #vim.fn.win_findbuf(buf) == 0 then
              pcall(vim.api.nvim_buf_delete, buf, { force = true })
            end
          end
        end
        vim.cmd("wincmd h | bdelete | wincmd l | close")
      end, { buffer = list_buf, desc = "Close diff view" })

      -- Window configuration
      vim.wo[0].statusline = "Diff Files: " .. branch .. " vs HEAD"
      vim.cmd("wincmd h")
      vim.notify("Ready to view diffs. Press Enter on a file to view its diff.", vim.log.levels.INFO)
    end, {
      nargs = 1,
      desc = "Compare current branch with specified branch",
      complete = function()
        local branches = vim.fn.systemlist("git branch --format='%(refname:short)' 2>/dev/null") or {}
        return branches
      end
    })

    -- Convenience command for main/master
    vim.api.nvim_create_user_command("DiffMain", function()
      local main_branch = vim.fn.system("git rev-parse --verify main 2>/dev/null || echo master"):gsub("%s+$", "")
      vim.cmd("DiffBranch " .. main_branch)
    end, {
      desc = "Compare current branch with main/master branch"
    })
  end,
}
