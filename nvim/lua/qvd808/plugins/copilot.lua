return {
  {
    "olimorris/codecompanion.nvim",
    -- v20+ requires Neovim 0.12; remove the pin after upgrading nvim
    tag = "v19.27.0",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "nvim-treesitter/nvim-treesitter",
    },
    cmd = { "CodeCompanionChat", "CodeCompanionActions", "CodeCompanion" },
    keys = {
      { "<leader>cc", "<cmd>CodeCompanionChat Toggle<cr>", mode = { "n", "v" }, desc = "Copilot chat" },
      { "<leader>ca", "<cmd>CodeCompanionActions<cr>",     mode = { "n", "v" }, desc = "Copilot actions" },
      { "<leader>cl", function() require("qvd808.custom.copilot").chats() end, desc = "Copilot open chats" },
      { "<leader>cm", function() require("qvd808.custom.copilot").model() end, desc = "Copilot model picker" },
      { "<leader>cr", function() require("qvd808.custom.copilot_ui").reasoning() end, desc = "Copilot reasoning level" },
      { "<leader>cf", function() require("qvd808.custom.copilot").changes() end, desc = "Files changed by Copilot" },
      { "<leader>ac", function() require("qvd808.custom.copilot_workflow").toggle() end, desc = "Copilot work units" },
    },
    config = function(_, opts)
      local ui = require("qvd808.custom.copilot_ui")
      opts = vim.tbl_deep_extend("force", opts, { display = ui.display, interactions = { chat = { roles = ui.roles } } })
      require("codecompanion").setup(opts)
      require("qvd808.custom.chat_agent").setup()
      ui.setup()
      require("qvd808.custom.copilot_workflow").setup()
      require("qvd808.custom.copilot").fix_slash_commands()
      require("qvd808.custom.copilot").setup_models()
    end,
    opts = {
      -- The Copilot CLI already loads ~/.copilot/copilot-instructions.md, AGENTS.md etc. itself; autoloading
      -- them here sends them twice and makes every session title "Sharing ...CLAUDE.md"
      rules = { opts = { chat = { enabled = false } } },
      -- Show the agent's skills (/wayfinder, /caveman) in the same "/" menu as the built-in slash commands
      opts = { triggers = { acp_slash_commands = "/" } },
      adapters = {
        acp = {
          codex = function()
            return require("codecompanion.adapters").extend("codex", {
              defaults = { auth_method = "chat-gpt" },
            })
          end,
          copilot_acp = function()
            return require("qvd808.custom.copilot_workflow").adapter(nil, "copilot_acp")
          end,
        },
      },
      -- No mcpServers override: copilot --acp loads ~/.copilot/mcp-config.json itself and rejects
      -- client-passed servers with the same name
      interactions = {
        chat = {
          adapter = require("qvd808.custom.chat_agent").preferred(),
          keymaps = {
            options = {
              callback = function()
                require("qvd808.custom.copilot_ui").help()
              end,
            },
          },
          tools = { opts = { approval_mode = "yolo" } }, -- "ask" | "auto" | "yolo"; the write gate still guards git repos
          slash_commands = { opts = { acp = { trigger = "/" } } },
        },
      },
    },
  },
}
