return {
  "stevearc/conform.nvim",
  config = function()
    require("conform").setup({
      format_on_save = {
        timeout_ms = 3000,
        lsp_format = "fallback",
      },
      formatters_by_ft = {
        c = { "clang-format" },
        cpp = { "clang-format" },
        lua = { "stylua" },
        rust = { "rustfmt" },
        go = { "goimports", "gofumpt" },
        python = { "ruff_organize_imports", "ruff_format" },
        toml = { "taplo" },
        sh = { "shfmt" },
        bash = { "shfmt" },
        javascript = { "prettier" },
        javascriptreact = { "prettier" },
        typescript = { "prettier" },
        typescriptreact = { "prettier" },
        json = { "prettier" },
        jsonc = { "prettier" },
        html = { "prettier" },
        css = { "prettier" },
        scss = { "prettier" },
        yaml = { "prettier" },
        markdown = { "prettier" },
      },
      formatters = {
        -- prepend_args merges with the builtin args; a plain `args` would replace
        -- them and drop the stdin/filename plumbing conform relies on.
        ["clang-format"] = {
          prepend_args = { "-style=file", "-fallback-style=LLVM" },
        },
        shfmt = {
          prepend_args = { "-i", "2", "-bn", "-ci" },
        },
      },
    })

    -- Manual format shortcut
    vim.keymap.set("n", "<leader>f", function()
      require("conform").format({ bufnr = 0 })
    end, { desc = "Format current buffer" })
  end,
}
