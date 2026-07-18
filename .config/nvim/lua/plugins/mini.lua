return {
  {
    "echasnovski/mini.nvim",
    version = false,
    event = { "BufReadPre", "BufNewFile" },
    config = function()
      require('mini.ai').setup()
      -- require('mini.surround').setup()
      -- require('mini.operators').setup()
      -- require('mini.pairs').setup()  -- autopairs removed (annoying)
      require('mini.bracketed').setup()
      -- require('mini.files').setup()  -- using oil.nvim as the file explorer instead
    end,
  },
}
