vim.keymap.set("n", "<C-s>", "<cmd>w<cr>", { desc = "Save Buffer", silent = true })
vim.keymap.set("n", "<C-S-a>", "ggVG", { desc = "Select All Buffer", silent = true })
vim.keymap.set("n", "<C-c>", "<cmd>%y+<cr>", { desc = "Copy All Buffer", silent = true })
-- vim.keymap.set("n", "<leader>q", "<cmd>bd!<cr>", { desc = "Close Buffer", silent = true })
vim.keymap.set("n", "J", "mzJ`z", { desc = "Join lines and restore cursor position", silent = true })
vim.keymap.set("n", "<C-d>", "<C-d>zz", { desc = "Scroll down half a page and recenter", silent = true })
vim.keymap.set("n", "<C-u>", "<C-u>zz", { desc = "Scroll up half a page and recenter", silent = true })
vim.keymap.set("n", "n", "nzzzv", { desc = "Find next and recenter", silent = true })
vim.keymap.set("n", "N", "Nzzzv", { desc = "Find previous and recenter", silent = true })
vim.keymap.set("n", "*", "*zz", { desc = "Search word under cursor and recenter", silent = true })

vim.keymap.set("n", "<leader>;", function()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local line_content = vim.api.nvim_buf_get_lines(0, line - 1, line, false)[1]
  if line_content:sub(-1) == ";" then
    line_content = line_content:sub(1, -2)
  else
    line_content = line_content .. ";"
  end
  vim.api.nvim_buf_set_lines(0, line - 1, line, false, { line_content })
end, { desc = "Toggle semicolon at end of line", silent = true })

-- Visual mode mappings
local function visual_move(down)
  local mode = vim.fn.mode()
  
  local start_pos = vim.fn.getpos("v")
  local end_pos = vim.fn.getpos(".")
  local before = vim.fn.getline(start_pos[2])
  
  local start_line = start_pos[2]
  local end_line = end_pos[2]
  
  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end
  
  if down then
    vim.cmd(start_line .. "," .. end_line .. "m" .. end_line + 1)
  else
    vim.cmd(start_line .. "," .. end_line .. "m" .. (start_line - 2))
  end
  
  local new_start = start_pos[2] + (down and 1 or -1)
  local new_end = end_pos[2] + (down and 1 or -1)
  
  local after = vim.fn.getline(new_start)
  
  local before_col = before:find("%S") or (#before + 1)
  local after_col = after:find("%S") or (#after + 1)
  local shift = after_col - before_col
  
  -- Exit visual mode
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  
  -- Update positions
  start_pos[2] = new_start
  end_pos[2] = new_end
  start_pos[3] = start_pos[3] + shift
  end_pos[3] = end_pos[3] + shift
  
  -- Set cursor to new start position
  vim.fn.setpos(".", start_pos)
  
  -- Enter the correct visual mode
  if mode == "V" then
    vim.cmd("normal! V")
  elseif mode == "\22" then
    vim.cmd("normal! " .. string.char(22))
  else
    vim.cmd("normal! v")
  end
  
  -- Set cursor to new end position
  vim.fn.setpos(".", end_pos)
end

local function visual_indent(right)
  local mode = vim.fn.mode()
  
  if mode == "V" then
    vim.cmd("normal! " .. (right and ">" or "<") .. "gv")
    return
  end
  
  local start_pos = vim.fn.getpos("v")
  local end_pos = vim.fn.getpos(".")
  local before = vim.fn.getline(start_pos[2])
  
  vim.cmd("normal! gv" .. (right and ">" or "<"))
  
  local after = vim.fn.getline(start_pos[2])
  
  local before_col = before:find("%S") or (#before + 1)
  local after_col = after:find("%S") or (#after + 1)
  local shift = after_col - before_col
  
  if shift == 0 then return end
  
  start_pos[3] = start_pos[3] + shift
  end_pos[3] = end_pos[3] + shift
  
  vim.fn.setpos(".", start_pos)
  if mode == "\22" then
    vim.cmd("normal! " .. string.char(22))
  else
    vim.cmd("normal! v")
  end
  vim.fn.setpos(".", end_pos)
end

vim.keymap.set("v", "J", function() visual_move(true) end, { desc = "Move visual selection down", silent = true })
vim.keymap.set("v", "K", function() visual_move(false) end, { desc = "Move visual selection up", silent = true })
vim.keymap.set("v", "<S-Down>", function() visual_move(true) end, { desc = "Move visual selection down", silent = true })
vim.keymap.set("v", "<S-Up>", function() visual_move(false) end, { desc = "Move visual selection up", silent = true })
vim.keymap.set("v", "<S-Right>", function() visual_indent(true) end, { desc = "Indent selection", silent = true })
vim.keymap.set("v", "<S-Left>", function() visual_indent(false) end, { desc = "Dedent selection", silent = true })


-- Folding
vim.keymap.set('n', 'zR', function() vim.cmd('set foldlevel=999') end, { desc = 'Folds: Open all folds' })
vim.keymap.set('n', 'zM', function() vim.cmd('set foldlevel=0') end, { desc = 'Folds: Close all folds' })
vim.keymap.set('n', 'za', 'za', { desc = 'Folds: Toggle current fold' })
vim.keymap.set('n', 'zA', 'zA', { desc = 'Folds: Toggle current fold recursively' })
vim.keymap.set('n', 'zc', 'zc', { desc = 'Folds: Close current fold' })
vim.keymap.set('n', 'zC', 'zC', { desc = 'Folds: Close current fold recursively' })
vim.keymap.set('n', 'zo', 'zo', { desc = 'Folds: Open current fold' })
vim.keymap.set('n', 'zO', 'zO', { desc = 'Folds: Open current fold recursively' })
