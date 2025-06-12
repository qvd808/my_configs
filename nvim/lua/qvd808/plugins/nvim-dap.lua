return {
  {
    "mfussenegger/nvim-dap",
    lazy = true,
    -- Copied from LazyVim/lua/lazyvim/plugins/extras/dap/core.lua and
    -- modified.
    keys = {
      {
        "<leader>b",
        function() require("dap").toggle_breakpoint() end,
        desc = "Toggle Breakpoint"
      },

      {
        "<leader>cc",
        function() require("dap").continue() end,
        desc = "Continue"
      },

      {
        "<leader>dC",
        function() require("dap").run_to_cursor() end,
        desc = "Run to Cursor"
      },

      {
        "<leader>dT",
        function() require("dap").terminate() end,
        desc = "Terminate"
      },
    },
  },
  {
    "jay-babu/mason-nvim-dap.nvim",
    ---@type MasonNvimDapSettings
    opts = {
      -- This line is essential to making automatic installation work
      -- :exploding-brain
      handlers = {},
      automatic_installation = false,
      -- DAP servers: Mason will be invoked to install these if necessary.
      ensure_installed = {
        "python",
      },
    },
    dependencies = {
      "mfussenegger/nvim-dap",
      "williamboman/mason.nvim",
    },
  },
  {
    "mfussenegger/nvim-dap-python",
    lazy = true,
    config = function()
      local python = vim.fn.expand("~/.local/share/nvim/mason/packages/debugpy/venv/bin/python")
      require("dap-python").setup(python)
    end,
    -- Consider the mappings at
    -- https://github.com/mfussenegger/nvim-dap-python?tab=readme-ov-file#mappings
    dependencies = {
      "mfussenegger/nvim-dap",
    },
  },
  {
    "theHamsta/nvim-dap-virtual-text",
    config = true,
    dependencies = {
      "mfussenegger/nvim-dap",
    },
  },
  {
    "rcarriga/nvim-dap-ui",
    config = true,
    keys = {
      {
        "<leader>du",
        function()
          require("dapui").toggle({})
        end,
        desc = "Dap UI"
      },
    },
    dependencies = {
      "jay-babu/mason-nvim-dap.nvim",
      "mfussenegger/nvim-dap-python",
      "nvim-neotest/nvim-nio",
      "theHamsta/nvim-dap-virtual-text",
    },
  }
}
