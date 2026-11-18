# Optional terminal graphics

Chat (`<leader>cc`) can display Markdown image links and Mermaid fences through
Snacks image documents. The workflow (`<leader>ac`) appends a Mermaid diagram
highlighting the selected unit's actual state. Its existing text diagram,
details, and action keys remain available, including if conversion fails.

Install the configured `folke/snacks.nvim` plugin through Lazy, Markdown and
Markdown-inline Tree-sitter parsers through the existing configuration, plus
ImageMagick (`magick`) and Mermaid CLI (`mmdc`, including its browser runtime).
No dependency is installed automatically by this integration.

Automatic selection accepts Kitty, Ghostty and WezTerm identification. Inside
tmux, Snacks identifies the outer terminal. Mermaid CLI and ImageMagick
(`magick` or the Ubuntu `convert` executable) are required. Unsupported or
unknown terminals, Zellij and missing dependencies retain text. Set `NVIM_TERMINAL_GRAPHICS=0`
before starting Neovim to disable this integration. Restart after installing
dependencies or changing terminal settings.

Snacks confirms terminal protocol support; support is never forced. In tmux,
enable `set -g allow-passthrough on` if needed. Over SSH, retain the terminal
identification variables and install conversion tools on the remote host;
Snacks handles image transfer. WSL automatically enables Snacks remote byte
transfer (`SNACKS_SSH=true`) because Windows cannot read Linux image paths. Environment identification alone does not
guarantee the enclosing terminal supports graphics.

Text and Mermaid source are never concealed. On terminals without inline
placeholders, Snacks uses a cursor-triggered floating preview. Conversion errors
leave the source readable. Use `:checkhealth snacks` to diagnose terminal,
parser and conversion dependencies. Chat diagrams render when their Markdown
fences are complete, rather than on every streamed token.

Reference: [Snacks image documentation](https://github.com/folke/snacks.nvim/blob/main/docs/image.md).

Validation: headless tests cover conservative capability selection, tmux/SSH
environment handling, missing dependencies, renderer exceptions and selected
workflow state. Actual terminal pixels and live chat streaming require an
interactive Kitty/Ghostty session with dependencies installed.


## Windows WezTerm with Ubuntu WSL

In your **Windows** WezTerm configuration, add this assignment before the existing
`return config` (adapt to your config table name):

```lua
config.enable_kitty_graphics = true
```

This repository does not contain your Windows WezTerm configuration. Reload it
and open a fresh WSL tab. Test without tmux first; then repeat inside tmux with
`set -g allow-passthrough on` in its configuration.

Run dependency setup **inside WSL**, not PowerShell. For Ubuntu 24.04:

```sh
sudo apt-get update
sudo apt-get install imagemagick
npm install --prefix "$HOME/.local/share/nvim-graphics" @mermaid-js/mermaid-cli
export PATH="$HOME/.local/share/nvim-graphics/node_modules/.bin:$PATH"
```

Add that PATH export to your shell startup file before launching Neovim.
Use a Node version supported by the current Mermaid CLI package. Its Puppeteer
browser must also run inside WSL. If conversion reports missing browser/system
libraries, resolve that specific error before testing Neovim; do not disable the
browser sandbox to hide it.

Confirm conversion independently:

```sh
command -v mmdc
command -v magick || command -v convert
printf 'flowchart LR
  A --> B
' > /tmp/nvim-graphics-test.mmd
mmdc -i /tmp/nvim-graphics-test.mmd -o /tmp/nvim-graphics-test.png
file /tmp/nvim-graphics-test.png
```

Expected: a PNG image. The final Mermaid command exercises the browser runtime;
merely finding `mmdc` on PATH does not prove conversion works.

Restart Neovim, install Snacks via `:Lazy`, and install parsers with
`:TSInstall markdown markdown_inline`. Run `:TerminalGraphicsCheck` for missing
commands/selection and `:checkhealth snacks` for terminal/parser diagnostics.
Missing conversion tools are reported explicitly rather than appearing to be a
successful graphics setup. These diagnostics do not prove pixels are visible.

Physical acceptance checks:

1. Open `<leader>cc` and request a fenced Mermaid block containing
   `flowchart LR` followed by `A --> B`. Wait for the complete response, then move
   the cursor **inside the Mermaid fence in Normal mode**. In WezTerm expect a
   floating graphical preview, not an inline diagram. Source remains readable.
2. Open `<leader>ac`, scroll to **Optional workflow graphic**, and put the cursor
   inside its Mermaid fence. Expect a floating diagram with the selected unit's
   current status highlighted. Existing workflow text and action keys still work.
3. Move away from the block and close/reopen each view; the preview should close
   or update without leaving stale graphics. Repeat inside tmux if you use it.
4. Restart with `NVIM_TERMINAL_GRAPHICS=0 nvim`: chat and workflow remain usable
   as text without previews. Unset the variable and restart to restore graphics.

If protocol detection cannot identify WezTerm through tmux, first test in a
plain WezTerm WSL tab. Only when you know the outer terminal is WezTerm, try
`SNACKS_WEZTERM=true nvim` to identify it explicitly. This does not enable the
Windows graphics setting for you. Report diagnostics and conversion stderr if
no preview appears; do not accept on automated tests alone.

Sources: [Snacks terminal environments](https://github.com/folke/snacks.nvim/blob/main/lua/snacks/image/terminal.lua),
[byte/file transport](https://github.com/folke/snacks.nvim/blob/main/lua/snacks/image/image.lua),
[WezTerm configuration source](https://github.com/wezterm/wezterm/blob/main/config/src/config.rs),
[Mermaid CLI installation](https://github.com/mermaid-js/mermaid-cli#installation).

After restarting Neovim, physically verify both chat and workflow previews:
hover Mermaid near the bottom of the screen, scroll away/back, resize WezTerm,
change splits, and close/reopen both views. Repeat with a visible tabline.
Images must stay inside their borders and disappear on close. Automated tests
check protocol output and position caching, not Windows terminal pixels.

Mermaid previews now render with an opaque black image background and dark
Mermaid theme. The hover window also uses a black background with zero blending,
restored after colorscheme changes. A separate image-opaque-black-v1 cache avoids
reusing transparent conversions; the previous cache is left intact.
After restarting Neovim, hover Mermaid in both chat and workflow over dense text.
Check that no source text shows through, labels remain readable, and closing the
preview restores the unobscured source. Repeat after changing colorscheme.
