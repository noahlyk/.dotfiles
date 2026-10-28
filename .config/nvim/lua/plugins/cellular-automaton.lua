return {
  "Eandrju/cellular-automaton.nvim",
  cmd = { "CellularAutomaton" },
  keys = {
    {
      "<leader>rb",
      function()
        local animations = {}
        local ca = require("cellular-automaton")
        for name, _ in pairs(ca.animations) do
          table.insert(animations, name)
        end
        -- skip ca.start_animation: its tree-sitter parser guard rejects filetypes without a parser
        require("cellular-automaton.manager").execute_animation(ca.animations[animations[math.random(#animations)]])
      end,
      desc = "CellularAutomaton random animation",
    },
  },
  config = function()
    -- no parser for this buffer: treat as unhighlighted instead of erroring
    local get_captures_at_pos = vim.treesitter.get_captures_at_pos
    vim.treesitter.get_captures_at_pos = function(...)
      local ok, captures = pcall(get_captures_at_pos, ...)
      return ok and captures or {}
    end
    require("cellular-automaton").register_animation {
      fps = 144,
      name = "slide",
      update = function(grid)
        for i = 1, #grid do
          local prev = grid[i][#grid[i]]
          for j = 1, #grid[i] do
            grid[i][j], prev = prev, grid[i][j]
          end
        end
        return true
      end,
    }
  end,
}
