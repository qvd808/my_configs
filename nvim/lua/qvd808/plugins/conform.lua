return {
  "stevearc/conform.nvim",
  opts = {},
  config = function()
    require("conform").setup({
      format_on_save = {
        timeout_ms = 3000,
        lsp_format = "fallback", -- use LSP if no formatter configured
      },
      formatters_by_ft = {
        c = { "clang-format" },
        cpp = { "clang-format" },
        lua = { "stylua" },
        javascript = { "prettier" },
        typescript = { "prettier" },
        rust = { "rustfmt" },
      },
      formatters = {
        ["clang-format"] = {
          prepend_args = { "-style=file", "-fallback-style=LLVM" },
        },
        ["rustfmt"] = {
          command = "rustfmt",
          args = { "--edition", "2021" },
        },
      },
    })

    -- Manual format shortcut
    vim.keymap.set("n", "<leader>f", function()
      require("conform").format({ bufnr = 0 })
    end, { desc = "Format current buffer" })
  end,
}
