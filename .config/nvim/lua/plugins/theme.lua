local function set_custom_highlights()

  -- No bg
  vim.api.nvim_set_hl(0, "Normal", { bg = "NONE" })
  vim.api.nvim_set_hl(0, "NormalNC", { bg = "NONE" })
  vim.api.nvim_set_hl(0, "EndOfBuffer", { bg = "NONE" })

  local dark_gray = "#484a4a"
  vim.api.nvim_set_hl(0, "@comment", { fg = dark_gray })
  vim.api.nvim_set_hl(0, "LspInlayHint", { fg = dark_gray, bg = "NONE" })

  -- LineNr needs more contrast than comments/inlay hints: dark_gray on a
  -- transparent (terminal) bg is ~2:1, which makes the digits unreadable.
  local line_nr_gray = "#8a8a8a"
  vim.api.nvim_set_hl(0, "LineNr", { fg = line_nr_gray })
  vim.api.nvim_set_hl(0, "CursorLineNr", { fg = "#FF9E3B", bold = true })

  local async_color = "#FF1493" -- Hot pink
  local await_color = "#FF69B4" -- Deep pink

  vim.api.nvim_set_hl(0, "@lsp.typemod.function.async", { fg = async_color })
  vim.api.nvim_set_hl(0, "@lsp.typemod.method.async", { fg = async_color })
  vim.api.nvim_set_hl(0, "@lsp.typemod.function.call.async", { fg = async_color })
  vim.api.nvim_set_hl(0, "@lsp.typemod.method.call.async", { fg = async_color })
  vim.api.nvim_set_hl(0, "@keyword.coroutine", { fg = await_color })
end


local colorscheme_file = vim.fn.stdpath('cache') .. '/colorscheme.txt'

vim.api.nvim_create_autocmd('ColorScheme', {
  pattern = '*',
  callback = function()
    local colorscheme = vim.g.colors_name
    vim.fn.writefile({ colorscheme }, colorscheme_file)
    set_custom_highlights()
  end,
})

vim.api.nvim_create_autocmd('VimEnter', {
  pattern = '*',
  callback = function()
    if vim.fn.filereadable(colorscheme_file) == 1 then
      local colorscheme = vim.fn.readfile(colorscheme_file)[1]
      vim.cmd.colorscheme(colorscheme)
      set_custom_highlights()
    end
  end,
})


-- plain native hybrid line numbers; no custom statuscolumn renderer
vim.o.number = true
vim.o.relativenumber = true

return {
  {
    "rose-pine/neovim",
    name = "rose-pine",
    lazy = false,
    priority = 1000,
    config = function()
      vim.api.nvim_create_autocmd("VimEnter", {
        callback = function()
          vim.cmd("colorscheme rose-pine")
          set_custom_highlights()
        end,
      })
    end
  },
}
