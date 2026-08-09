return {
  "mfussenegger/nvim-lint",
  event = {
    "BufReadPre",
    "BufNewFile",
  },
  config = function()
    local lint = require("lint")
    lint.linters_by_ft = {
      python = { "ruff" },
      yaml = { "yamllint" },
      go = { "golangcilint" },
      javascript = { "eslint_d" },
      javascriptreact = { "eslint_d" },
      typescript = { "eslint_d" },
      typescriptreact = { "eslint_d" },
    }

    -- eslint_d errors out when a project has no eslint config, so only run it
    -- where one actually exists.
    local eslint_configs = {
      "eslint.config.js",
      "eslint.config.mjs",
      "eslint.config.cjs",
      "eslint.config.ts",
      ".eslintrc",
      ".eslintrc.js",
      ".eslintrc.cjs",
      ".eslintrc.json",
      ".eslintrc.yaml",
      ".eslintrc.yml",
    }

    local function has_eslint_config(bufnr)
      local dir = vim.fs.dirname(vim.api.nvim_buf_get_name(bufnr))
      if dir == nil or dir == "" then
        return false
      end
      return vim.fs.find(eslint_configs, { path = dir, upward = true })[1] ~= nil
    end

    -- golangci-lint walks the whole package, so keep it off the hot path.
    local write_only = { golangcilint = true }

    local function linters_for(bufnr, event)
      local names = lint.linters_by_ft[vim.bo[bufnr].filetype]
      if not names then
        return {}
      end

      local run = {}
      for _, name in ipairs(names) do
        local skip = (name == "eslint_d" and not has_eslint_config(bufnr))
          or (write_only[name] and event ~= "BufWritePost")
        if not skip then
          table.insert(run, name)
        end
      end
      return run
    end

    local lint_augroup = vim.api.nvim_create_augroup("lint", { clear = true })

    vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "InsertLeave" }, {
      group = lint_augroup,
      callback = function(args)
        local run = linters_for(args.buf, args.event)
        if #run > 0 then
          lint.try_lint(run)
        end
      end,
    })

    vim.keymap.set("n", "<space>ll", function()
      local run = linters_for(0, "BufWritePost")
      if #run > 0 then
        lint.try_lint(run)
      end
    end, { desc = "Trigger linting for the current file" })
  end,
}
