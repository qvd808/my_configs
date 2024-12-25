return {
  {
    "neovim/nvim-lspconfig",
    dependencies = {
      -- Automatically install LSPs and related tools to stdpath for Neovim
      { 'williamboman/mason.nvim', config = true }, -- NOTE: Must be loaded before dependants
      'williamboman/mason-lspconfig.nvim',
      { 'folke/neodev.nvim',       opts = {} },     -- Use for configuring Lua LSP
    },
    config = function()
      -- List of servers to install and configure
      local servers = {
        lua_ls = {},      -- Lua
        pyright = {},     -- Python
        clangd = {},      -- C/C++
        ts_ls = {},       -- Typescript/Javascript
        tailwindcss = {}, --Tailwind
        zls = {}          -- Zig
      }

      -- Setup capabilities
      local capabilities = vim.lsp.protocol.make_client_capabilities()
      capabilities = vim.tbl_deep_extend('force', capabilities, require('cmp_nvim_lsp').default_capabilities())

      -- Setup Mason
      require("mason-lspconfig").setup({
        ensure_installed = vim.tbl_keys(servers), -- Install listed servers
        automatic_installation = true
      })

      -- Setup LSP servers
      local lspconfig = require("lspconfig")
      for server, config in pairs(servers) do
        config.capabilities = capabilities
        lspconfig[server].setup(config)
      end

      -- Adding LSP option on LspAttach
      vim.api.nvim_create_autocmd("LspAttach", {
        callback = function(args)
          local client = vim.lsp.get_client_by_id(args.data.client_id) if not client then return end

          -- Formatting on save
          if client.supports_method("textDocument/formatting") then
            vim.api.nvim_create_autocmd("BufWritePre", {
              buffer = args.buf,
              callback = function()
                vim.lsp.buf.format({ async = false })
              end
            })
          end

          -- Diagnostic keymaps
          vim.keymap.set("n", "<leader>e", vim.diagnostic.setqflist, { desc = "Show diagnostic [E]rror message" })
          vim.keymap.set("n", "<C-e>", vim.diagnostic.open_float, { desc = "Show diagnostic [E]rror message" })
          vim.keymap.set("n", "grn", vim.lsp.buf.rename)
          vim.keymap.set("n", "gra", vim.lsp.buf.code_action)
          vim.keymap.set("n", "grr", vim.lsp.buf.references)
          vim.keymap.set("i", "<C-s>", vim.lsp.buf.signature_help)
          vim.keymap.set("n", 'K', vim.lsp.buf.hover, { desc = 'Hover Documentation' })
          vim.keymap.set("n", 'gI', require('telescope.builtin').lsp_implementations, { desc = '[G]oto [I]mplementation'})
          vim.keymap.set("n", 'gd', require('telescope.builtin').lsp_definitions, {desc = 'Go to Definition'})
        end,
      })
    end
  }
}
