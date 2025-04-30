return {
  {
    "nvim-telescope/telescope.nvim",
    tag = "0.1.8",
    dependencies = {
      "nvim-lua/plenary.nvim",
      { "nvim-telescope/telescope-fzf-native.nvim", build = "make" }
    },

    -- Setting up theme for each find files
    config = function()
      require("telescope").setup({
        pickers = {
          find_files = {
            theme = "ivy"
          },
          builtin = {
            theme = "dropdown"
          },
          lsp_references = {
            theme = "ivy"
          },
          help_tags = {
            theme = "dropdown"
          }
        },
        extensions = {
          fzf = {}
        }
      })

      require("telescope").load_extension("fzf")
      vim.keymap.set("n", "<space>ff", require("telescope.builtin").find_files)
      vim.keymap.set("n", "<space>bi", require("telescope.builtin").builtin)
      vim.keymap.set("n", "<space>rr", require("telescope.builtin").lsp_references)
      vim.keymap.set("n", "<space>fh", require("telescope.builtin").help_tags)
      vim.keymap.set("n", "<space>gb", require("telescope.builtin").git_branches)
      vim.keymap.set("n", 'gd', require('telescope.builtin').lsp_definitions, { desc = '[G]oto [D]efinition' })
    end
  }
}
