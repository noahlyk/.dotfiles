return {
  "tpope/vim-fugitive",
  cmd = { "G", "Git", "Gvdiffsplit", "GlLog" },
  keys = {
    { "<leader>gs", "<cmd>G<CR>", desc = "Git Status" },
    {
      "<leader>gl",
      function()
        local function refresh(buf)
          vim.bo[buf].modifiable = true
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn.systemlist("git log --all --decorate --oneline --graph"))
          vim.bo[buf].modifiable = false
        end

        if vim.b[0].is_git_log then
          refresh(0)
          return
        end

        for _, b in ipairs(vim.api.nvim_list_bufs()) do
          if vim.b[b].is_git_log and vim.api.nvim_buf_is_loaded(b) then
            for _, w in ipairs(vim.api.nvim_list_wins()) do
              if vim.api.nvim_win_get_buf(w) == b then
                vim.api.nvim_set_current_win(w)
                refresh(b)
                return
              end
            end
          end
        end

        vim.cmd("Git log --all --decorate --oneline --graph")
        vim.b[0].is_git_log = true
      end,
      desc = "Git Log",
    },
    { "<leader>gL", "<cmd>GlLog<CR>", desc = "Git Advanced Log" },
    { "<leader>gf", "<cmd>Git fetch<CR>", desc = "Git Fetch" },
    { "<leader>gp", "<cmd>Git pull<CR>", desc = "Git Pull" },
    { "<leader>gP", "<cmd>Git push<CR>", desc = "Git Push" },
    { "<leader>gir", "<cmd>Git rebase -i --root<CR>", desc = "Git Rebase Interactive (root)" },
    { "<leader>git", "<cmd>Git rebase -i HEAD~10<CR>", desc = "Git Rebase Interactive (last 10 commits)" },
    { "<leader>gc", "<cmd>Telescope git_branches<CR>", desc = "Git Checkout" },
  },
}
