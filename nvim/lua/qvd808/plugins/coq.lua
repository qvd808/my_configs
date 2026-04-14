return {
  {
    "whonore/Coqtail",
    ft = "coq",
    init = function()
      local opam_prefix = vim.fn.expand("$HOME") .. "/.opam/default"
      local opam_bin = opam_prefix .. "/bin"

      if not vim.env.PATH:find(opam_bin, 1, true) then
        vim.env.PATH = opam_bin .. ":" .. vim.env.PATH
      end

      vim.env.COQLIB = opam_prefix .. "/lib/coq"
      vim.env.COQCORELIB = opam_prefix .. "/lib/coq-core"
      vim.env.ROCQPATH = opam_prefix .. "/lib/coq/user-contrib"
      vim.env.ROCQRUNTIMELIB = opam_prefix .. "/lib/rocq-runtime"

      vim.filetype.add({ extension = { v = "coq" } })

      vim.g.coqtail_nomap = 1
      vim.g.coqtail_supported = 1
      vim.g.coqtail_coq_path = opam_bin

      if vim.fn.executable(opam_bin .. "/coqidetop") == 1 then
        vim.g.coqtail_coq_prog = "coqidetop"
      elseif vim.fn.executable(opam_bin .. "/rocqtop") == 1 then
        vim.g.coqtail_coq_prog = "rocqtop"
      elseif vim.fn.executable(opam_bin .. "/coqtop") == 1 then
        vim.g.coqtail_coq_prog = "coqtop"
      end
    end,
    config = function()
      vim.keymap.set("n", "<M-j>", function()
        vim.cmd("CoqNext")
        vim.defer_fn(function() vim.cmd("CoqJumpToEnd") end, 100)
      end, { desc = "Coq Step Forward" })

      vim.keymap.set("n", "<M-k>", function()
        vim.cmd("CoqUndo")
        vim.defer_fn(function() vim.cmd("CoqJumpToEnd") end, 100)
      end, { desc = "Coq Step Backward" })

      vim.keymap.set("n", "<M-l>", "<Plug>CoqToLine", { desc = "Coq Step to Cursor" })
    end,
  },
}
