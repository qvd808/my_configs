return {
  {
    "mfussenegger/nvim-dap",
    dependencies = {
      --   "jay-babu/mason-nvim-dap.nvim",

      -- For Dap Ui
      "rcarriga/nvim-dap-ui",
      "nvim-neotest/nvim-nio",
      { "theHamsta/nvim-dap-virtual-text", config = true },

      -- Mason intergration
      "williamboman/mason.nvim",

      -- Debugger
      "mfussenegger/nvim-dap-python", -- python
      -- "jedrzejboczar/nvim-dap-cortex-debug" -- Embedded
    },
    config = function()
      local dap = require("dap")
      local ui = require("dapui")

      require("dapui").setup()

      local python = vim.fn.expand("~/.local/share/nvim/mason/packages/debugpy/venv/bin/python")
      require("dap-python").setup(python) -- Need to install debugpy through mason

      dap.adapters.cppdbg = {
        id = 'cppdbg',
        type = 'executable',
        command = '/root/.local/share/nvim/mason/bin/OpenDebugAD7'
      }

      vim.keymap.set("n", "<leader>b", dap.toggle_breakpoint, { desc = "Toggle Breakpoint" })
      vim.keymap.set("n", "<leader>cc", dap.continue, { desc = "Continue" })
      vim.keymap.set("n", "<leader>dC", dap.run_to_cursor, { desc = "Run to Cursor" })
      vim.keymap.set("n", "<leader>dT", dap.terminate, { desc = "Terminate" })

      vim.keymap.set("n", "<leader>si", dap.step_into, { desc = "Step Into" })
      vim.keymap.set("n", "<leader>so", dap.step_over, { desc = "Step Over" })
      vim.keymap.set("n", "<leader>st", dap.step_out, { desc = "Step Out" })
      vim.keymap.set("n", "<leader>ss", dap.restart, { desc = "Restart" })

      vim.keymap.set("n", "<leader>du", ui.toggle, { desc = "Toggle UI" })

      dap.listeners.before.attach.dapui_config = function()
        ui.open()
      end
      dap.listeners.before.launch.dapui_config = function()
        ui.open()
      end
      dap.listeners.before.event_terminated.dapui_config = function()
        ui.close()
      end
      dap.listeners.before.event_exited.dapui_config = function()
        ui.close()
      end
    end,
  },
}
