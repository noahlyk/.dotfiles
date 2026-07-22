return {
  {
    "noahlyk/oil.nvim",
    lazy = false,
    keys = {
      { "<leader>e", "<cmd> Oil <cr>", desc = "Open Oil (explorer)" },
    },
    dependencies = {
      { "echasnovski/mini.icons", opts = {} },
    },
    opts = {
      default_file_explorer = true,
      restore_win_options = true,
      use_default_keymaps = false,
      keymaps = {
        ["g?"] = "actions.show_help",
        ["<CR>"] = "actions.select",
        ["<C-p>"] = "actions.preview",
        ["<C-n>"] = "actions.close",
        ["<C-r>"] = "actions.refresh",
        ["-"] = "actions.parent",
        ["_"] = "actions.open_cwd",
        ["`"] = "actions.cd",
        ["~"] = "actions.tcd",
        ["gs"] = "actions.change_sort",
        ["gx"] = "actions.open_external",
        ["g."] = "actions.toggle_hidden",
        ["g\\"] = "actions.toggle_trash",
      },
      view_options = {
        show_hidden = true,
        is_always_hidden = function(name)
          return name == ".."
        end,
      },
      preview_win = {
        preview_split = "right",
      },
    },

    init = function()
      vim.api.nvim_create_autocmd("VimEnter", {
        callback = function()
          if vim.fn.argc() == 0 then
            vim.defer_fn(function()
              require("oil").open()
            end, 0)
          end
        end,
      })
    end,

  },

  -- {
  --   "malewicz1337/oil-git.nvim",
  --   dependencies = { "noahlyk/oil.nvim" },
  -- },

}
