local o = vim.o
local opt = vim.opt

vim.g.mapleader = ' '
vim.g.maplocalleader = ' '  -- was 'localmapleader' (not a real option) -> localleader was unset

vim.filetype.add({ extension = { ron = "ron" } })

o.clipboard = 'unnamedplus'

o.tabstop = 2
o.softtabstop = 2
o.shiftwidth = 2
o.expandtab = true
o.smartindent = true

o.wrap = false

-- search
o.ignorecase = true
o.smartcase = true

-- splits open in a sane direction
o.splitright = true
o.splitbelow = true

-- live :substitute preview
o.inccommand = "split"

-- always-on gutter (stops text jitter from gitsigns/diagnostics) + current-line highlight
o.signcolumn = "yes"
o.cursorline = true

-- prompt to save instead of erroring on :q with unsaved changes
o.confirm = true

o.swapfile = false
o.backup = false
o.undodir = (os.getenv "XDG_STATE_HOME" or os.getenv "HOME" .. "/.local/state") .. "/nvim/undo"
vim.fn.mkdir(o.undodir, "p")
o.undofile = true

o.termguicolors = true

o.scrolloff = 8
opt.isfname:append "@-@"

opt.fillchars = { eob = " " }

o.updatetime = 50

o.colorcolumn = "0"

vim.api.nvim_create_autocmd("TextYankPost", {
  desc = "Highlight when yanking (copying) text",
  group = vim.api.nvim_create_augroup("highlight-yank", { clear = true }),
  callback = function()
    vim.hl.on_yank({ higroup = "IncSearch", timeout = 200 })
  end,
})

-- Folding
vim.o.foldmethod = "expr"  -- Use treesitter for folding
vim.o.foldexpr = "nvim_treesitter#foldexpr()"
vim.o.foldlevel = 99       -- Start with all folds open
vim.o.foldnestmax = 10     -- Maximum fold nesting level
vim.o.foldminlines = 1     -- Minimum lines needed to fold
