return {
  "stevearc/conform.nvim",
  opts = {},
  config = function()
    local uv = vim.loop
    local project_root = vim.fn.getcwd()

    -- check if .prettierrc exists in project root
    local prettier_config = project_root .. "/.prettierrc"
    local config_exists = uv.fs_stat(prettier_config)
    if not config_exists then
      prettier_config = nil -- fallback to Prettier default
    end

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
          args = vim.tbl_flatten({
            prettier_config and { "--config", prettier_config } or {},
            "--stdin-filepath",
            "$FILENAME",
          }),
        },
      },
    })

    -- Manual format shortcut
    vim.keymap.set("n", "<leader>f", function()
      require("conform").format({ bufnr = 0 })
    end, { desc = "Format current buffer" })
  end,
}
