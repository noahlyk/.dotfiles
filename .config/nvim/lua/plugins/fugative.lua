-- Git-log window: fugitive's own interactive log buffer (so ri / cc / rr / ce /
-- <CR> and friends keep working), plus toggle, live auto-refresh, and real colors.
--
-- Live-refresh is event-driven: we subscribe to the repo's .git directory with
-- libuv filesystem watchers (vim.uv.new_fs_event) and refresh on change. No polling,
-- no signature diffing, no fixed-delay guessing. The old two-timer poll was the
-- source of the "sometimes it just stops updating" bug (its self-destruct-on-
-- transient-invalid callback killed the timer permanently). See git history.
--
-- inotify isn't recursive on Linux, so we watch the git dir top-level (HEAD, index,
-- packed-refs, FETCH_HEAD...) AND every directory under refs/ (loose refs live in
-- the leaves, e.g. refs/remotes/origin/main — which is all a `git push` rewrites).

local FUGITIVE_LOG = "Git log --oneline --graph --decorate --all"      -- opens the buffer
local LOG_CMD = { "git", "log", "--oneline", "--graph", "--decorate", "--all" }
local DEBOUNCE_MS = 60   -- coalesce the burst of fs events one git op fires into one refresh
local FALLBACK_MS = 5000 -- slow poll, used ONLY if the fs watcher can't arm (e.g. inotify exhaustion)

local M = {
  buf = nil,
  win = nil,
  root = nil,      -- repo dir we run git in / resolved the watch from
  gitdirs = nil,   -- resolved base git dir(s): --absolute-git-dir (+ --git-common-dir)
  watched = nil,   -- set { [abs dir] = true } of directories currently armed
  watchers = nil,  -- list of active fs_event handles (nil = not watching)
  debounce = nil,  -- reusable one-shot uv_timer
  fallback = nil,  -- slow poll timer, only when watchers can't arm
  job_running = false,
  job_pending = false,
}
local ns = vim.api.nvim_create_namespace("gitlog")
local re_hash = vim.regex([[\<\x\{7,40}\>]])

-- forward declarations (these functions reference each other)
local ensure_watching, rearm, schedule_refresh, tick, refresh_log
local on_fs_event, arm, stop_watchers, start_fallback, stop_fallback

local function win_valid()
  return M.win and vim.api.nvim_win_is_valid(M.win)
end

local function buf_valid()
  return M.buf and vim.api.nvim_buf_is_valid(M.buf)
end

-- ===================================================================== colors ==
-- Mirror git's own log palette so HEAD / branches / remotes / tags are each
-- distinct instead of all white. Re-asserted on every paint because a
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

-- ============================================================ status window ====
-- <leader>gs is fugitive's own `filetype=fugitive` buffer; it doesn't self-refresh
-- on FugitiveChanged, but a silent :edit reloads it in place.
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

-- ================================================================= refresh =====
-- Re-run the log async and rewrite the same fugitive buffer in place (so its maps
-- survive), then repaint. vim.system keeps the UI responsive even on huge repos —
-- the old synchronous vim.fn.systemlist was itself a source of jank/lockups.
function refresh_log()
  if not buf_valid() then return end
  if M.job_running then M.job_pending = true; return end -- coalesce overlapping runs
  M.job_running = true
  local cursor = win_valid() and vim.api.nvim_win_get_cursor(M.win) or nil
  vim.system(LOG_CMD, { cwd = M.root or vim.fn.getcwd(), text = true }, function(obj)
    vim.schedule(function()
      M.job_running = false
      if buf_valid() then
        local out = (obj.code == 0 and obj.stdout) or ""
        local lines = vim.split(out, "\n", { trimempty = true })
        if #lines == 0 then lines = { "" } end -- fresh repo w/ no commits, etc.
        local mod = vim.bo[M.buf].modifiable
        vim.bo[M.buf].modifiable = true
        vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
        vim.bo[M.buf].modifiable = mod
        paint()
        if cursor and win_valid() then
          cursor[1] = math.min(cursor[1], math.max(1, #lines))
          pcall(vim.api.nvim_win_set_cursor, M.win, cursor)
        end
      end
      if M.job_pending then -- something changed while we were running: run once more
        M.job_pending = false
        refresh_log()
      end
    end)
  end)
end

local function log_open()
  return win_valid() and buf_valid()
end

local function any_target_open()
  return log_open() or status_win() ~= nil
end

-- The single entry point every trigger funnels into. Refreshes whichever of the
-- log / status windows is open. rearm() first, cheaply, so a push/branch that
-- created a brand-new refs/ subdir (new remote or namespace) gets a watch on it.
function tick()
  rearm()
  if log_open() then refresh_log() end
  status_refresh()
end

-- Debounce: one reusable one-shot timer; each trigger stops+restarts it so a burst
-- of fs events (one git op fires ~5-10) collapses into a single refresh. The timer
-- op itself is libuv-native (safe to call from an fs_event fast-context callback);
-- all Vim work happens in the schedule-wrapped timer callback.
function schedule_refresh()
  if not M.debounce then M.debounce = vim.uv.new_timer() end
  M.debounce:stop()
  M.debounce:start(DEBOUNCE_MS, 0, vim.schedule_wrap(tick))
end

-- ============================================================ fs watcher =======
-- Raw fs_event callback: fast (libuv) context — do NOTHING here but re-arm on error
-- and kick the debounce timer. No vim.api / vim.system allowed here.
function on_fs_event(err)
  if err then
    -- watch may have gone stale (rare: a watched dir removed) — re-resolve & re-arm
    vim.schedule(function()
      M.watchers, M.watched, M.gitdirs = nil, nil, nil
      ensure_watching()
    end)
    return
  end
  schedule_refresh()
end

function stop_watchers()
  if M.watchers then
    for _, w in ipairs(M.watchers) do
      w:stop()
      if not w:is_closing() then w:close() end
    end
    M.watchers = nil
  end
end

function stop_fallback()
  if M.fallback then
    M.fallback:stop()
    if not M.fallback:is_closing() then M.fallback:close() end
    M.fallback = nil
  end
end

function start_fallback()
  if M.fallback then return end
  M.fallback = vim.uv.new_timer()
  M.fallback:start(FALLBACK_MS, FALLBACK_MS, vim.schedule_wrap(function()
    if any_target_open() then tick() else stop_fallback() end
  end))
end

-- Arm one fs_event per directory. We watch *directories* (not files) so git's
-- atomic rename (index.lock -> index, main.lock -> main) can't leave us watching a
-- dead inode. Returns true if at least one watch armed.
function arm(dirs)
  stop_watchers()
  M.watchers = {}
  local ok_any = false
  for _, d in ipairs(dirs) do
    local w = vim.uv.new_fs_event()
    -- luv returns 0 (truthy in Lua) on success, or nil,err on failure
    local ok = w:start(d, {}, on_fs_event)
    if ok then
      ok_any = true
      table.insert(M.watchers, w)
    else
      pcall(function() w:close() end)
    end
  end
  if ok_any then
    stop_fallback()
  else
    -- inotify exhausted / unsupported FS: degrade to a slow poll instead of dying
    M.watchers = nil
    start_fallback()
  end
  return ok_any
end

-- Every directory to watch for a git dir: the dir itself (HEAD/index/packed-refs/
-- FETCH_HEAD) plus every subdirectory of refs/ (loose refs live in the leaves; a
-- push only writes refs/remotes/<remote>/<branch>, nested 2+ deep). logs/ is
-- skipped — reflogs don't affect `git log --all` output.
local function collect_dirs(gitdir, acc)
  acc[gitdir] = true
  local function walk(dir)
    acc[dir] = true
    local req = vim.uv.fs_scandir(dir)
    if not req then return end
    while true do
      local name, typ = vim.uv.fs_scandir_next(req)
      if not name then break end
      local child = dir .. "/" .. name
      if typ == "directory" or (typ == nil and (vim.uv.fs_stat(child) or {}).type == "directory") then
        walk(child)
      end
    end
  end
  local refs = gitdir .. "/refs"
  if vim.uv.fs_stat(refs) then walk(refs) end
end

local function dirset_equal(a, b)
  if not a or not b then return false end
  for k in pairs(a) do if not b[k] then return false end end
  for k in pairs(b) do if not a[k] then return false end end
  return true
end

-- Recompute the full set of dirs to watch and (re)arm only if it changed — so the
-- per-refresh call is a cheap refs/ walk with no watcher churn in the common case,
-- but a newly-created refs/ subdir (first push to a new remote, new namespace) gets
-- picked up automatically.
function rearm()
  if not M.gitdirs then return end
  local acc = {}
  for _, g in ipairs(M.gitdirs) do collect_dirs(g, acc) end
  if dirset_equal(acc, M.watched) then return end
  local list = {}
  for d in pairs(acc) do table.insert(list, d) end
  M.watched = arm(list) and acc or nil -- clear on failure so the next tick retries
end

local function absolutize(p, base)
  if p == "" then return nil end
  if p:sub(1, 1) ~= "/" then p = base .. "/" .. p end
  return vim.fs.normalize(p)
end

-- Resolve the repo's git dir(s) async, then arm watchers. Watch the common dir
-- (shared refs/tags/packed-refs for --all) and, in a linked worktree, also the
-- per-worktree dir (its HEAD/index). In a normal repo the two are equal -> one base.
function ensure_watching()
  if not any_target_open() then return end
  local root = vim.fn.getcwd()
  if M.watchers and M.root == root then return end -- already watching this repo
  M.root = root
  stop_watchers()
  M.gitdirs, M.watched = nil, nil
  vim.system(
    { "git", "-C", root, "rev-parse", "--absolute-git-dir", "--git-common-dir" },
    { text = true },
    vim.schedule_wrap(function(obj)
      if obj.code ~= 0 then return end -- not a git repo; nothing to watch
      local parts = vim.split(obj.stdout, "\n", { trimempty = true })
      local seen, gd = {}, {}
      for _, p in ipairs({ parts[1], parts[2] }) do
        local abs = p and absolutize(p, root)
        if abs and not seen[abs] then
          seen[abs] = true
          table.insert(gd, abs)
        end
      end
      if #gd == 0 then return end
      M.gitdirs = gd
      rearm()
    end)
  )
end

-- Tear everything down once neither the log nor the status window is open.
local function maybe_stop()
  if not any_target_open() then
    stop_watchers()
    stop_fallback()
    if M.debounce then
      M.debounce:stop()
      if not M.debounce:is_closing() then M.debounce:close() end
      M.debounce = nil
    end
    M.root, M.gitdirs, M.watched = nil, nil, nil
  end
end

-- ============================================================ lifecycle ========
local function close()
  if win_valid() then
    pcall(vim.api.nvim_win_close, M.win, true)
  end
  M.win, M.buf = nil, nil
  maybe_stop()
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

  paint()           -- fugitive already filled the buffer; just color it
  ensure_watching() -- subscribe to the repo; refreshes flow from fs events
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
      refresh_log()
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
          refresh_log()
          return
        end
      end
    end
  end

  open()
end

-- <leader>gs: close if focused on it, jump if open elsewhere, open otherwise
function M.status_toggle()
  local wn = status_win()
  if wn then
    if vim.api.nvim_get_current_win() == wn then
      pcall(vim.api.nvim_win_close, wn, true)
      maybe_stop()
    else
      vim.api.nvim_set_current_win(wn)
      status_refresh()
    end
    return
  end
  vim.cmd("Git")    -- fugitive opens its native status split
  ensure_watching() -- subscribe so the status buffer live-refreshes too
end

-- ================================================================ autocmds =====
local aug = vim.api.nvim_create_augroup("GitLogWindow", { clear = true })

-- fugitive fires this on checkout/commit/rebase/etc done inside nvim — an instant
-- trigger. Funnels into the same debounced refresh as the fs watcher.
vim.api.nvim_create_autocmd("User", {
  group = aug,
  pattern = "FugitiveChanged",
  callback = function()
    if any_target_open() then
      ensure_watching()
      schedule_refresh()
    end
  end,
})

-- Belt-and-suspenders + recovery: on focus regained (a change from another terminal)
-- re-arm the watcher if it died and refresh.
vim.api.nvim_create_autocmd("FocusGained", {
  group = aug,
  callback = function()
    if any_target_open() then
      ensure_watching()
      schedule_refresh()
    end
  end,
})

-- cwd changed to a different repo while a window is open — re-resolve & re-watch.
vim.api.nvim_create_autocmd("DirChanged", {
  group = aug,
  callback = function()
    if any_target_open() then
      stop_watchers()
      M.watchers, M.root, M.gitdirs, M.watched = nil, nil, nil, nil
      ensure_watching()
      schedule_refresh()
    end
  end,
})

-- Any window closing: drop log state if it was ours, then release the watcher if
-- nothing's left open (covers closing the status window via fugitive's own maps).
vim.api.nvim_create_autocmd("WinClosed", {
  group = aug,
  callback = function(args)
    if M.win and tonumber(args.match) == M.win then
      M.win, M.buf = nil, nil
    end
    vim.schedule(maybe_stop)
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
