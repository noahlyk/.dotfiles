-- Git tooling on top of tpope/vim-fugitive + rbong/vim-flog.
--
-- The log/graph is handled by vim-flog (real commit-graph rendering, its own
-- coloring, and its own libuv fs_event live-refresh). What lives here is:
--   * the git STATUS window (fugitive's :Git buffer) + its live auto-refresh, and
--   * a `coo` checkout-under-cursor override for flog buffers.
--
-- Status live-refresh is event-driven: we subscribe to the repo's .git directory
-- with libuv filesystem watchers (vim.uv.new_fs_event) and refresh on change. No
-- polling, no signature diffing, no fixed-delay guessing. (The old two-timer poll
-- was the source of the "sometimes it just stops updating" bug — its self-destruct-
-- on-transient-invalid callback killed the timer permanently. See git history.)
--
-- flog's watcher can't be reused for this: its callback is hardcoded to flog
-- buffers and fires no autocmd, so there's nothing to subscribe to. So the status
-- window keeps its own watcher (this file) — one consumer now instead of two.
--
-- inotify isn't recursive on Linux, so we watch the git dir top-level (HEAD, index,
-- packed-refs, FETCH_HEAD...) AND every directory under refs/ (loose refs live in
-- the leaves, e.g. refs/remotes/origin/main — which is all a `git push` rewrites).

local DEBOUNCE_MS = 60   -- coalesce the burst of fs events one git op fires into one refresh
local FALLBACK_MS = 5000 -- slow poll, used ONLY if the fs watcher can't arm (e.g. inotify exhaustion)

local M = {
  root = nil,      -- repo dir we run git in / resolved the watch from
  gitdirs = nil,   -- resolved base git dir(s): --absolute-git-dir (+ --git-common-dir)
  watched = nil,   -- set { [abs dir] = true } of directories currently armed
  watchers = nil,  -- list of active fs_event handles (nil = not watching)
  debounce = nil,  -- reusable one-shot uv_timer
  fallback = nil,  -- slow poll timer, only when watchers can't arm
}

-- forward declarations (these functions reference each other)
local ensure_watching, rearm, schedule_refresh, tick
local on_fs_event, arm, stop_watchers, start_fallback, stop_fallback

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

local function any_target_open()
  return status_win() ~= nil
end

-- ================================================================= refresh =====
-- The single entry point every trigger funnels into. rearm() first, cheaply, so a
-- push/branch that created a brand-new refs/ subdir (new remote or namespace) gets
-- a watch on it, then refresh the status window in place.
function tick()
  rearm()
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
-- skipped — reflogs don't affect status output.
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
-- (shared refs/tags/packed-refs) and, in a linked worktree, also the per-worktree
-- dir (its HEAD/index). In a normal repo the two are equal -> one base.
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

-- Tear everything down once the status window is closed.
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

-- ==================================================== checkout under cursor ====
-- flog/fugitive's `coo` resolves the commit HASH on the line, so hovering a branch
-- name still detaches HEAD. This resolves the *ref token* under the cursor first: a
-- local branch checks out attached; a remote-tracking ref (origin/x) DWIMs to its
-- local tracking branch; otherwise it falls back to the line's commit hash
-- (detached, the same as the default coo).
local function ref_exists(ref)
  vim.fn.system({ "git", "-C", M.root or vim.fn.getcwd(), "rev-parse", "--verify", "--quiet", ref })
  return vim.v.shell_error == 0
end

local function token_under_cursor(line, col) -- col is 1-based
  local i = 1
  while true do
    local s, e = line:find("[%w%._/-]+", i)
    if not s then return nil end
    if col >= s and col <= e then return line:sub(s, e) end
    i = e + 1
  end
end

local function checkout_under_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local tok = token_under_cursor(line, col)
  local target
  if tok and tok ~= "HEAD" and tok ~= "tag:" then
    if ref_exists("refs/heads/" .. tok) then
      target = tok                     -- local branch → attach to it
    elseif ref_exists("refs/remotes/" .. tok) then
      target = tok:gsub("^[^/]+/", "") -- origin/x → x (switch to / create tracking branch)
    elseif ref_exists("refs/tags/" .. tok) then
      target = tok                     -- tag → checkout (detached, as expected)
    end
  end
  target = target or line:match("(%x%x%x%x%x%x%x+)") -- else the commit hash (detached, like coo)
  if not target then
    vim.notify("git log: nothing checkout-able under the cursor", vim.log.levels.WARN)
    return
  end
  vim.cmd("Git checkout " .. target) -- fugitive checkout → fires FugitiveChanged → live refresh
end

-- ============================================================ lifecycle ========
-- <leader>gl: close if focused on a flog window, jump to it if open elsewhere,
-- otherwise open one. (flog's own auto-update keeps it fresh, so no manual refresh.)
function M.log_toggle()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "floggraph" then
      if vim.api.nvim_get_current_win() == w then
        pcall(vim.api.nvim_win_close, w, true)
      else
        vim.api.nvim_set_current_win(w)
      end
      return
    end
  end
  vim.cmd("Flog")
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

-- ================================================================= colors ======
-- flog links its groups to muted defaults (flogHash->Statement, flogRef->Directory,
-- flogRefRemote->Statement, flogRefTag->String, flogRefHead->Keyword) which collapse
-- to near-identical in this colorscheme. Restore the old vibrant semantic palette.
-- Re-asserted on ColorScheme (a scheme's `hi clear` wipes these) and per flog buffer
-- (flog re-links its `default` groups on load; a non-default set here wins).
local function set_flog_highlights()
  local hl = vim.api.nvim_set_hl
  hl(0, "flogHash",          { fg = "#E0AF68" })              -- commit hash: yellow
  hl(0, "flogRef",           { fg = "#9ECE6A", bold = true }) -- local branch: green
  hl(0, "flogRefRemote",     { fg = "#F7768E", bold = true }) -- origin/*: red
  hl(0, "flogRefTag",        { fg = "#E0AF68", bold = true }) -- tag: yellow
  hl(0, "flogRefHead",       { fg = "#7DCFFF", bold = true }) -- HEAD: cyan
  hl(0, "flogRefHeadBranch", { fg = "#9ECE6A", bold = true }) -- branch after HEAD ->: green
  hl(0, "flogRefHeadArrow",  { fg = "#6C7086" })              -- the -> arrow: dim
end

-- ================================================================ autocmds =====
local aug = vim.api.nvim_create_augroup("GitStatusWindow", { clear = true })

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

-- cwd changed to a different repo while the status window is open — re-resolve & re-watch.
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

-- Any window closing: release the watcher if nothing's left open (covers closing the
-- status window via fugitive's own maps).
vim.api.nvim_create_autocmd("WinClosed", {
  group = aug,
  callback = function()
    vim.schedule(maybe_stop)
  end,
})

-- coo override on flog graph buffers: attach to the BRANCH under the cursor when
-- hovering a ref name; else the commit under the cursor (detached) — unlike the
-- default coo, which always takes the line's hash.
vim.api.nvim_create_autocmd("FileType", {
  group = aug,
  pattern = "floggraph",
  callback = function(a)
    set_flog_highlights() -- flog re-links its default groups on load; win over them
    -- The bracket-conceal + origin/* red syntax lives in after/syntax/floggraph.vim
    -- (must load *after* flog's syntax so its `containedin` binds; doing it here is
    -- load-order dependent and silently no-ops when this autocmd runs first). We only
    -- own the window options here.
    vim.opt_local.conceallevel = 2
    vim.opt_local.concealcursor = "nvic"
    vim.keymap.set("n", "coo", checkout_under_cursor,
      { buffer = a.buf, silent = true, desc = "Checkout ref/commit under cursor" })
  end,
})

-- restore flog's ref/hash colors after a colorscheme change (hi clear wipes them)
vim.api.nvim_create_autocmd("ColorScheme", {
  group = aug,
  callback = function() vim.schedule(set_flog_highlights) end,
})

set_flog_highlights()

return {
  {
    "tpope/vim-fugitive",
    cmd = { "G", "Git", "Gvdiffsplit", "GlLog" },
    keys = {
      { "<leader>gs", M.status_toggle, desc = "Git Status (toggle)" },
      { "<leader>gl", M.log_toggle, desc = "Git Log (flog, toggle)" },
      { "<leader>gL", "<cmd>GlLog<CR>", desc = "Git Advanced Log" },
      { "<leader>gf", "<cmd>Git fetch<CR>", desc = "Git Fetch" },
      { "<leader>gp", "<cmd>Git pull<CR>", desc = "Git Pull" },
      { "<leader>gP", "<cmd>Git push<CR>", desc = "Git Push" },
      { "<leader>gir", "<cmd>Git rebase -i --root<CR>", desc = "Git Rebase Interactive (root)" },
      { "<leader>git", "<cmd>Git rebase -i HEAD~10<CR>", desc = "Git Rebase Interactive (last 10 commits)" },
      { "<leader>gc", "<cmd>Telescope git_branches<CR>", desc = "Git Checkout" },
    },
  },
  {
    "rbong/vim-flog",
    dependencies = { "tpope/vim-fugitive" },
    cmd = { "Flog", "Flogsplit", "Floggit" },
    init = function()
      -- off (default is ON in Neovim): dynamic branch hl recolors branch names with
      -- generated colors, overriding the static semantic palette (green local / red
      -- remote) set in set_flog_highlights().
      vim.g.flog_enable_dynamic_branch_hl = 0
      vim.g.flog_default_opts = {
        all = true,          -- mirror the old `git log --all` view
        auto_update = true,  -- turn Neovim live-updates on explicitly
        -- simple `--oneline --decorate` line: short hash, ref names, subject.
        -- flog's default is the verbose "%ad [%h] {%an}%d %s" — drop the date +
        -- author (noise in a solo repo). Keep [%h] bracketed and %d: flog's
        -- syntax only colors the hash inside [ ], and that match anchors the
        -- ref/HEAD/tag/remote highlighting chain — a bare %h greys out the
        -- whole line.
        format = "[%h]%d %s",
      }
    end,
  },
}
