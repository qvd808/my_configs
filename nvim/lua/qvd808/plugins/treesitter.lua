return {
  {
    -- Pin to master: the `main` rewrite needs Nvim 0.12+ and removed
    -- `nvim-treesitter.configs` (what this setup still uses on 0.11).
    "nvim-treesitter/nvim-treesitter",
    branch = "master",
    lazy = false,
    -- Keep queries/parsers in sync whenever lazy updates the plugin.
    build = ":TSUpdate",
    config = function()
      require("nvim-treesitter.configs").setup({
        ensure_installed = {
          "c", "lua", "vim", "vimdoc", "query",
          "markdown", "markdown_inline",
          "javascript", "typescript", "python",
        },
        auto_install = true,
        highlight = {
          enable = true,
          disable = function(_, buf)
            local max_filesize = 100 * 1024 -- 100 KB
            local ok, stats = pcall(vim.uv.fs_stat, vim.api.nvim_buf_get_name(buf))
            if ok and stats and stats.size > max_filesize then
              return true
            end
          end,
          additional_vim_regex_highlighting = false,
        },
      })
    end,
  },
}
