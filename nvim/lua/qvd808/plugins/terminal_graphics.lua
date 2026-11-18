return {
  {
    "folke/snacks.nvim",
    lazy = false,
    priority = 1000,
    opts = function()
      require("qvd808.custom.terminal_graphics").configure_transport()
      return { image = {
        enabled = require("qvd808.custom.terminal_graphics").available(),
        force = false,
        -- WezTerm does not support placeholders: its hover must cover source text.
        doc = { enabled = true, inline = true, float = true,
          wo = { winblend = 0, winhighlight = "Normal:TerminalGraphicsPreview,NormalFloat:TerminalGraphicsPreview" },
          conceal = function() return false end },
        math = { enabled = false },
        -- Separate cache avoids reusing previously generated transparent images.
        cache = vim.fn.stdpath("cache") .. "/snacks/image-opaque-black-v1",
        convert = { notify = false, mermaid = {
          "-i", "{src}", "-o", "{file}", "-b", "#000000", "-t", "dark", "-s", "{scale}",
        } },
      } }
    end,
    config = function(_, opts)
      require("snacks").setup(opts)
      require("qvd808.custom.terminal_graphics").fix_placement()
      require("qvd808.custom.terminal_graphics").setup()
    end,
  },
}
