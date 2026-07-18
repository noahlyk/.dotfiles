local function set_custom_highlights()

  -- No bg
  vim.api.nvim_set_hl(0, "Normal", { bg = "NONE" })
  vim.api.nvim_set_hl(0, "NormalNC", { bg = "NONE" })
  vim.api.nvim_set_hl(0, "EndOfBuffer", { bg = "NONE" })

  local dark_gray = "#484a4a"
  vim.api.nvim_set_hl(0, "@comment", { fg = dark_gray })
  vim.api.nvim_set_hl(0, "LspInlayHint", { fg = dark_gray, bg = "NONE" })

  vim.api.nvim_set_hl(0, "LineNr", { fg = dark_gray })
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


function _G.update_status_column()
  if not ( vim.wo.number or vim.wo.relativenumber ) then
    return "%s" -- do nothing
  end
  local line_number = vim.v.lnum
  local current_line = vim.fn.line('.')
  if line_number == current_line then
    if not vim.wo.number then
      line_number = 0
    end
    if vim.wo.relativenumber then
      return "%s%#CursorLineNr# " .. line_number .. "❯%#NONE# "
    else
      return "%s%#CursorLineNr# :" .. line_number .. "❯%#NONE# "
    end
  end
  if not vim.wo.relativenumber then
    return "%#LineNr#%s:" .. line_number
  end
  local relative_number = line_number - current_line
  if relative_number < 0 then
    return "%#LineNr#%s" .. math.abs(relative_number) .. "k "
  elseif relative_number > 0 then
    return "%#LineNr#%s" .. math.abs(relative_number) .. "j "
  end
end

vim.o.number = true
vim.o.relativenumber = true
-- vim.cmd.colorscheme "catppuccin"

vim.api.nvim_create_autocmd("VimEnter", {
  callback = function()
    vim.defer_fn(function()
      vim.o.statuscolumn = "%{%v:lua.update_status_column()%}"
    end, 0)
  end,
})

vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
  callback = function()
    if not vim.wo.relativenumber then
      vim.wo.statuscolumn = vim.wo.statuscolumn
    end
  end,
})

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
