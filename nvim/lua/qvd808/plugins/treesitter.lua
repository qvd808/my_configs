return {
  {
    "nvim-treesitter/nvim-treesitter",
    branch = "master",
    build = ":TSUpdate",

    config = function()
      require("nvim-treesitter.configs").setup({
        ensure_installed = {
          "c",
          "lua",
          "vim",
          "vimdoc",
          "query",
          "markdown",
          "markdown_inline",
        },

        auto_install = true,

        highlight = {
          enable = true,

          disable = function(_, buf)
            local max_filesize = 100 * 1024

            local ok, stats = pcall(vim.uv.fs_stat, vim.api.nvim_buf_get_name(buf))

            return ok and stats and stats.size > max_filesize
          end,

          additional_vim_regex_highlighting = false,
        },
      })
    end,
  },
}
