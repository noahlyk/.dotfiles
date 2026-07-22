-- Enable Neovim's Lua module bytecode cache before anything is require()d.
-- Biggest startup win: lazy.nvim's spec parsing and every require() below reuse
-- compiled Lua instead of recompiling on each start.
vim.loader.enable()

-- Skip probing for language hosts we don't use (each would otherwise cost a
-- PATH lookup / process spawn at startup). node is left enabled on purpose --
-- markdown-preview.nvim needs it.
vim.g.loaded_perl_provider = 0
vim.g.loaded_ruby_provider = 0
vim.g.loaded_python3_provider = 0

require "core.options"
require "core.lazy"
require "core.mappings"
