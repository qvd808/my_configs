return {
	{
		"scottmckendry/cyberdream.nvim",
		lazy = false,
		priority = 1000,
		opts = {},
	},

	{
		"scottmckendry/cyberdream.nvim",
		name = "cyberdream",
		config = function()

			require("cyberdream").setup({
				transparent = true,
				terminal_colors = true,
				borderless_telescope = true,

				italic_comments = true
			})

			vim.cmd("colorscheme cyberdream")
		end
	},
}
