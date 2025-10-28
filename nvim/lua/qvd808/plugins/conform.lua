return {
  "stevearc/conform.nvim",
  opts = {},
  config = function()
    local project_root = vim.fn.getcwd() -- adjust if you want dynamic root detection

    require("conform").setup({
      format_on_save = {
        timeout_ms = 3000,
        lsp_format = "fallback",
      },
      async = true,
      formatters_by_ft = {
        c = { "clang-format" },
        cpp = { "clang-format" },
        lua = { "stylua" },
        javascript = { "prettier" },
        typescript = { "prettier" },
        json = { "prettier" },
        html = { "prettier" },
        css = { "prettier" },
        rust = { "rustfmt" },
        toml = { "taplo" },
        sh = { "shfmt" },
      },
      formatters = {
        ["clang-format"] = {
          prepend_args = { "-style=file", "-fallback-style=LLVM" },
        },
        ["rustfmt"] = {
          command = "rustfmt",
          args = { "--edition=2021" },
        },
        ["taplo"] = {
          command = "taplo",
          args = { "format", "-" },
        },
        ["shfmt"] = {
          command = "shfmt",
          args = { "-i", "2", "-bn", "-ci" },
        },
        ["prettier"] = {
          command = "prettier",
          args = {
            "--config",
            project_root .. "/.prettierrc", -- always use root config
            "--stdin-filepath",
            "$FILENAME",
          },
        },
      },
    })

    -- Manual format shortcut
    vim.keymap.set("n", "<leader>f", function()
      require("conform").format({ bufnr = 0 })
    end, { desc = "Format current buffer" })
  end,
}
