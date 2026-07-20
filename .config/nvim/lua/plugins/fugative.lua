-- Git-log window: fugitive's own interactive log buffer (so ri / cc / rr / ce /
-- <CR> and friends keep working), plus toggle, auto-refresh, and real colors.

local FUGITIVE_LOG = "Git log --oneline --graph --decorate --all" -- opens the buffer
local SHELL_LOG = "git log --oneline --graph --decorate --all"    -- used to refresh in place
local SIG_CMD = "git rev-parse HEAD --all 2>/dev/null"            -- cheap change signature
local IDLE_MS = 1000                                              -- background poll for external changes
local WATCH_MS = 40                                               -- fast poll while a change lands

local M = { buf = nil, win = nil, timer = nil, watcher = nil }
local ns = vim.api.nvim_create_namespace("gitlog")
local re_hash = vim.regex([[\<\x\{7,40}\>]])
local last_sig = nil

-- Cheap signature of HEAD + all ref shas; changes on any checkout/commit/rebase/
-- branch move. Fast even on large repos (unlike the full `git log`).
local function git_sig()
  return table.concat(vim.fn.systemlist(SIG_CMD), "\n")
end

local function win_valid()
  return M.win and vim.api.nvim_win_is_valid(M.win)
end

local function buf_valid()
  return M.buf and vim.api.nvim_buf_is_valid(M.buf)
end

-- Colors: mirror git's own log palette so HEAD / branches / remotes / tags are
-- each distinct instead of all white. Re-asserted on every paint because a
-- colorscheme's `hi clear` wipes custom groups.
local function set_highlights()
  local hl = vim.api.nvim_set_hl
  hl(0, "GitLogHash",   { fg = "#E0AF68" })              -- commit hash: yellow
  hl(0, "GitLogGraph",  { fg = "#6C7086" })              -- graph glyphs: dim
  hl(0, "GitLogParen",  { fg = "#6C7086" })              -- ( ) , -> : dim
  hl(0, "GitLogBranch", { fg = "#9ECE6A", bold = true }) -- local branch: green
  hl(0, "GitLogRemote", { fg = "#F7768E", bold = true }) -- remote branch: red
  hl(0, "GitLogTag",    { fg = "#E0AF68", bold = true }) -- tag: yellow bold
  hl(0, "GitLogHead",   { fg = "#7DCFFF", bold = true }) -- HEAD: bright cyan bold
end

-- Highlight one line with extmarks (independent of vim `syntax`, and drawn on top
-- of fugitive's own git syntax).
local function hl_line(buf, row, line)
  local function put(group, s, e) -- s,e are 0-based [start, end) byte cols
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, s, { end_col = e, hl_group = group })
  end

  local gs, ge = line:find("^[*|/\\ _.]+") -- graph glyphs at the start of the line
  if gs then put("GitLogGraph", gs - 1, ge) end

  local hs, he = re_hash:match_str(line) -- commit hash (first 7-40 hex word)
  if not hs then return end -- graph-only continuation line: nothing else to color
  put("GitLogHash", hs, he)

  -- git --decorate always puts refs immediately after the hash: "<hash> (refs) subject".
  -- If there's no " (" right there, the rest is the commit message (which may itself
  -- contain parentheses) — leave it uncolored.
  if line:sub(he + 1, he + 2) ~= " (" then return end
  local ps = he + 2 -- 1-based index of the opening "("
  local pe = line:find(")", ps, true)
  if not pe then return end

  put("GitLogParen", ps - 1, pe) -- dim the parens/commas/arrows underneath
  local i, prev_tag = ps + 1, false
  while true do
    local s, e = line:find("[%w%./_:-]+", i)
    if not s or s >= pe then break end
    local tok = line:sub(s, e)
    if tok:match("%w") then -- skip pure punctuation like "->"
      local grp = "GitLogBranch"
      if tok == "HEAD" then
        grp = "GitLogHead"
      elseif tok == "tag:" or prev_tag then
        grp = "GitLogTag"
      elseif tok:match("^origin/") then
        grp = "GitLogRemote"
      end
      put(grp, s - 1, e)
    end
    prev_tag = (tok == "tag:")
    i = e + 1
  end
end

local function paint()
  if not buf_valid() then return end
  set_highlights()
  vim.api.nvim_buf_clear_namespace(M.buf, ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(M.buf, 0, -1, false)
  for i, line in ipairs(lines) do
    hl_line(M.buf, i - 1, line)
  end
end

-- Re-run the log in place: keeps the same fugitive buffer (so its maps survive)
-- but pulls in any new commits, then repaints.
local function refresh()
  if not buf_valid() then return end
  local cursor = win_valid() and vim.api.nvim_win_get_cursor(M.win) or nil
  local lines = vim.fn.systemlist(SHELL_LOG)
  local mod = vim.bo[M.buf].modifiable
  vim.bo[M.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.bo[M.buf].modifiable = mod
  paint()
  if cursor and win_valid() then
    cursor[1] = math.min(cursor[1], math.max(1, #lines))
    pcall(vim.api.nvim_win_set_cursor, M.win, cursor)
  end
  last_sig = git_sig()
end

-- Refresh only if git state actually changed (keeps the idle poll cheap — the full
-- `git log` runs only when there's something new).
local function poll_refresh()
  if win_valid() and git_sig() ~= last_sig then refresh() end
end

local function stop_watcher()
  if M.watcher then
    M.watcher:stop()
    if not M.watcher:is_closing() then M.watcher:close() end
    M.watcher = nil
  end
end

-- Fixed delays can't catch a change on a big repo (checkout settles after them).
-- Instead poll the cheap signature until it differs from the pre-event state, then
-- refresh once — instant the moment the operation lands, whatever its duration.
local function watch_for_change()
  if not win_valid() then return end
  local base = last_sig or git_sig()
  stop_watcher()
  local tries = 0
  M.watcher = vim.uv.new_timer()
  M.watcher:start(WATCH_MS, WATCH_MS, vim.schedule_wrap(function()
    tries = tries + 1
    if not win_valid() then stop_watcher(); return end
    if git_sig() ~= base then
      refresh()
      stop_watcher()
    elseif tries >= 75 then -- ~3s safety cap
      stop_watcher()
    end
  end))
end

-- staggered reloads for the status buffer (cheap :edit); tail long enough to catch
-- a big-repo checkout settling.
local function status_burst(fn)
  vim.schedule(fn)
  for _, ms in ipairs({ 50, 150, 350, 700, 1200 }) do
    vim.defer_fn(fn, ms)
  end
end

-- === fugitive status window (<leader>gs): same toggle + live-refresh as the log ===
-- Status is fugitive's own `filetype=fugitive` buffer; it doesn't self-refresh on
-- FugitiveChanged, but a silent :edit reloads it in place.
local function status_win()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "fugitive" then
      for _, wn in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(wn) == b then return wn, b end
      end
    end
  end
end

local function status_refresh()
  local wn, b = status_win()
  if not b then return end
  local cur = vim.api.nvim_win_get_cursor(wn)
  pcall(vim.api.nvim_buf_call, b, function() vim.cmd("silent! edit") end)
  pcall(vim.api.nvim_win_set_cursor, wn, cur)
end

-- <leader>gs: close if focused on it, jump if open elsewhere, open otherwise
function M.status_toggle()
  local wn = status_win()
  if wn then
    if vim.api.nvim_get_current_win() == wn then
      pcall(vim.api.nvim_win_close, wn, true)
    else
      vim.api.nvim_set_current_win(wn)
      status_refresh()
    end
    return
  end
  vim.cmd("Git") -- fugitive opens its native status split
end

local function stop_timer()
  if M.timer then
    M.timer:stop()
    if not M.timer:is_closing() then M.timer:close() end
    M.timer = nil
  end
end

local function close()
  stop_timer()
  stop_watcher()
  if win_valid() then
    pcall(vim.api.nvim_win_close, M.win, true)
  end
  M.win, M.buf = nil, nil
end

local function attach(buf, win)
  M.buf, M.win = buf, win
  vim.b[buf].is_git_log = true
  vim.wo[win].number = true
  vim.wo[win].relativenumber = true
  vim.wo[win].wrap = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].statuscolumn = ""
  vim.wo[win].cursorline = true
  -- q closes the log (fugitive's other maps: ri, cc, rr, ce, <CR>, ... still work)
  vim.keymap.set("n", "q", close, { buffer = buf, silent = true, desc = "Close git log" })

  paint()
  last_sig = git_sig()
  stop_timer()
  M.timer = vim.uv.new_timer()
  M.timer:start(IDLE_MS, IDLE_MS, vim.schedule_wrap(function()
    if win_valid() then poll_refresh() else stop_timer() end
  end))
end

local function open()
  -- plain horizontal split of the current window (not a pinned side sidebar)
  vim.cmd("horizontal " .. FUGITIVE_LOG)
  local win = vim.api.nvim_get_current_win()
  attach(vim.api.nvim_get_current_buf(), win)
end

-- <leader>gl: close if focused on it, jump+refresh if open elsewhere, open otherwise
function M.toggle()
  if win_valid() then
    if vim.api.nvim_get_current_win() == M.win then
      close()
    else
      vim.api.nvim_set_current_win(M.win)
      refresh()
    end
    return
  end

  -- reuse an existing git-log window if one is around (e.g. after a colorscheme
  -- reload dropped our state)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.b[b].is_git_log then
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(w) == b then
          attach(b, w)
          vim.api.nvim_set_current_win(w)
          refresh()
          return
        end
      end
    end
  end

  open()
end

local aug = vim.api.nvim_create_augroup("GitLogWindow", { clear = true })
vim.api.nvim_create_autocmd({ "BufWritePost", "FocusGained" }, {
  group = aug,
  callback = function()
    vim.schedule(poll_refresh)   -- refresh log if git state changed (e.g. commit in another term)
    vim.schedule(status_refresh) -- no-op if the status window isn't open
  end,
})
-- fugitive fires this on checkout/commit/rebase/etc — watch for the change to land
-- and refresh the instant it does (no fixed-delay guessing), so HEAD/status update
-- immediately after coo/cc/... regardless of repo size.
vim.api.nvim_create_autocmd("User", {
  group = aug,
  pattern = "FugitiveChanged",
  callback = function()
    if win_valid() then watch_for_change() end
    if status_win() then status_burst(status_refresh) end
  end,
})
vim.api.nvim_create_autocmd("WinClosed", {
  group = aug,
  callback = function(args)
    if M.win and tonumber(args.match) == M.win then
      stop_timer()
      stop_watcher()
      M.win, M.buf = nil, nil
    end
  end,
})
-- repaint an open log after a colorscheme change (re-defines the groups too)
vim.api.nvim_create_autocmd("ColorScheme", {
  group = aug,
  callback = function()
    if win_valid() then vim.schedule(paint) end
  end,
})
set_highlights()

return {
  "tpope/vim-fugitive",
  cmd = { "G", "Git", "Gvdiffsplit", "GlLog" },
  keys = {
    { "<leader>gs", M.status_toggle, desc = "Git Status (toggle)" },
    { "<leader>gl", M.toggle, desc = "Git Log (toggle)" },
    { "<leader>gL", "<cmd>GlLog<CR>", desc = "Git Advanced Log" },
    { "<leader>gf", "<cmd>Git fetch<CR>", desc = "Git Fetch" },
    { "<leader>gp", "<cmd>Git pull<CR>", desc = "Git Pull" },
    { "<leader>gP", "<cmd>Git push<CR>", desc = "Git Push" },
    { "<leader>gir", "<cmd>Git rebase -i --root<CR>", desc = "Git Rebase Interactive (root)" },
    { "<leader>git", "<cmd>Git rebase -i HEAD~10<CR>", desc = "Git Rebase Interactive (last 10 commits)" },
    { "<leader>gc", "<cmd>Telescope git_branches<CR>", desc = "Git Checkout" },
  },
}
