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
        lua_ls = {},  -- Lua
        pyright = {}, -- Python
        clangd = {},  -- C/C++
        -- ts_ls = {},       -- Typescript/Javascript
        -- tailwindcss = {}, --Tailwind
        -- zls = {},         -- Zig
        -- arduino_language_server = {}, -- Arduino
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
          local client = vim.lsp.get_client_by_id(args.data.client_id)
          if not client then return end

          -- Detect if there is multiple compile_commands.json for clangd clients
          if client.name == "clangd" then
            vim.api.nvim_buf_create_user_command(args.buf, "SearchCompileCommands", function()
              local has_fd = vim.fn.executable("fd") == 1
              local find_command = has_fd
                  and { "fd", "--hidden", "--no-ignore", "compile_commands.json" }
                  or { "find", ".", "-name", "compile_commands.json" }

              -- Run the command and capture output
              local handle = io.popen(table.concat(find_command, " "))
              if not handle then
                vim.notify("Failed to run find command", vim.log.levels.ERROR)
                return
              end

              local result = handle:read("*a")
              handle:close()

              local files = {}
              for line in result:gmatch("[^\r\n]+") do
                table.insert(files, line)
              end

              if #files == 0 then
                vim.notify("No compile_commands.json files found", vim.log.levels.WARN)
                return
              elseif #files == 1 then
                local dir = vim.fn.fnamemodify(files[1], ":h")
                vim.notify("Using: " .. files[1])
                client.config.cmd = { "clangd", "--compile-commands-dir=" .. dir }
                vim.lsp.stop_client(client.id)
                vim.defer_fn(function()
                  vim.cmd("edit") -- reload buffer to trigger LspAttach
                end, 100)
              else
                vim.ui.select(files, {
                  prompt = "Select compile_commands.json for clangd",
                  format_item = function(item)
                    return vim.fn.fnamemodify(item, ":.")
                  end,
                }, function(choice)
                  if choice then
                    local dir = vim.fn.fnamemodify(choice, ":h")
                    vim.notify("Using: " .. choice)
                    client.config.cmd = { "clangd", "--compile-commands-dir=" .. dir }
                    vim.lsp.stop_client(client.id)
                    vim.defer_fn(function()
                      vim.cmd("edit") -- reload buffer to trigger LspAttach
                    end, 100)
                  end
                end)
              end
            end, { desc = "Search for compile_commands.json" })
          end


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
          vim.keymap.set("n", 'gI', require('telescope.builtin').lsp_implementations,
            { desc = '[G]oto [I]mplementation' })
          vim.keymap.set("n", 'gd', require('telescope.builtin').lsp_definitions, { desc = 'Go to Definition' })
        end,
      })
    end
  }
}
