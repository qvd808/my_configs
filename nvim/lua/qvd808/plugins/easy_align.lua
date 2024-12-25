return {
  "junegunn/vim-easy-align",
  cmd = "EasyAlign",
  config = function()
    -- Create command for whole file
    vim.api.nvim_create_user_command('EasyAlign', function(opts)
      -- If range is provided (visual selection), use it
      if opts.range > 0 then
        vim.cmd(string.format("%d,%dEasyAlign", opts.line1, opts.line2))
      else
        -- Otherwise align whole file
        vim.cmd("1,$EasyAlign")
      end
    end, { range = true })

    -- -- Visual mode mapping
    -- vim.keymap.set('x', '<leader>ea', '<Plug>(EasyAlign)', { desc = 'Easy Align' })
  end,
}
