return {
  { "ray-x/go.nvim", ft="go", },
  { "ray-x/guihua.lua", ft="go", },
  { "tpope/vim-sleuth", event = "BufReadPre", },
   {
     "numToStr/Comment.nvim",
     event = "VeryLazy",
     config = function()
       require('Comment').setup({
         ---Add a space b/w comment and the line
         padding = true,
         ---Whether the cursor should stay at its position
         sticky = true,
         ---Lines to be ignored while (un)comment
         ignore = nil,
         ---LHS of toggle mappings in NORMAL mode
         toggler = {
             ---Line-comment toggle keymap
             line = 'gcc',
             ---Block-comment toggle keymap
             block = 'gbc',
         },
         ---LHS of operator-pending mappings in NORMAL and VISUAL mode
         opleader = {
             ---Line-comment keymap
             line = 'gc',
             ---Block-comment keymap
             block = 'gb',
         },
         ---LHS of extra mappings
         extra = {
             ---Add comment on the line above
             above = 'gcO',
             ---Add comment on the line below
             below = 'gco',
             ---Add comment at the end of line
             eol = 'gcA',
         },
         ---Enable keybindings
         ---NOTE: If given `false` then the plugin won't create any mappings
         mappings = {
             ---Operator-pending mapping; `gcc` `gbc` `gc[count]{motion}` `gb[count]{motion}`
             basic = true,
             ---Extra mapping; `gco`, `gcO`, `gcA`
             extra = true,
         },
         ---Function to call before (un)comment
         pre_hook = nil,
         ---Function to call after (un)comment
         post_hook = nil,
       })

       -- Set commentstring for ron files
       vim.api.nvim_create_autocmd("BufReadPost", {
         pattern = "*.ron",
         callback = function()
           vim.opt_local.commentstring = "// %s"
         end,
       })
     end,
   },
  { "lukas-reineke/indent-blankline.nvim", main = "ibl", event="BufReadPost", },
  { "folke/twilight.nvim", ft = "markdown" },
  { "djoshea/vim-autoread", event = "BufRead" },
  {
    "3rd/image.nvim",
    build = false, -- so that it doesn't build the rock https://github.com/3rd/image.nvim/issues/91#issuecomment-2453430239
    -- Was a start plugin: it loaded eagerly AND probed the terminal for graphics
    -- support at startup (a likely cause of Oil feeling laggy on launch). VeryLazy
    -- lets Oil paint first, then image.nvim initializes right after.
    event = "VeryLazy",
    opts = { processor = "magick_cli", }
  },
}
