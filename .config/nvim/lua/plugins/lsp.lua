local servers = {
  cssls = {},
  html = {},
  phpactor = {},
  tailwindcss = {},
  gopls = {},
  pyright = {},
  clangd = {},
  omnisharp = {},
  jdtls = {},
  bashls = {},
  lua_ls = {
    settings = {
      Lua = {
        runtime = {
          version = 'LuaJIT',
        },
        diagnostics = {
          globals = { 'vim' },
        },
        hint = {
          enable = true,
        },
        workspace = {
          library = {
            vim.env.VIMRUNTIME .. '/lua',
          },
          checkThirdParty = false,
        },
      },
    },
  },
  ts_ls = {
    settings = {
      completions = {
        completeFunctionCalls = true,
      },
    },
  },
}

return {
  {
    "williamboman/mason.nvim",
    cmd = "Mason",
    event = "VeryLazy",
    opts = {
      ui = {
        icons = {
          package_installed = "✓",
          package_pending = "➜",
          package_uninstalled = "✗"
        }
      }
    },
    config = function(_, opts)
      require("mason").setup(opts)
    end,
  },
  {
    "williamboman/mason-lspconfig.nvim",
    dependencies = { "williamboman/mason.nvim" },
    event = "VeryLazy",
    config = function()
      require("mason-lspconfig").setup({
        automatic_installation = false,
      })
    end
  },
  {
    name = "lsp-setup",
    dir = vim.fn.stdpath("config"),
    event = { "BufReadPre", "BufNewFile" },
    dependencies = {
      "hrsh7th/cmp-nvim-lsp",
      "mason.nvim",
      "mason-lspconfig.nvim",
      "neovim/nvim-lspconfig",
    },
    config = function()
      -- New 0.11+ way to get capabilities
      local capabilities = vim.lsp.protocol.make_client_capabilities()
      capabilities = vim.tbl_deep_extend('force', capabilities,
        require('cmp_nvim_lsp').default_capabilities())

      -- Define & register server configs (Nvim 0.11+ API)
      for server, config in pairs(servers) do
        local cfg = vim.tbl_deep_extend("force", { capabilities = capabilities }, config)
        vim.lsp.config(server, cfg)
      end

      -- Enable the configs so they auto-attach for their filetypes
      for server, _ in pairs(servers) do
        vim.lsp.enable(server)
      end

      -- Keymaps
      vim.keymap.set("n", "grn", vim.lsp.buf.rename, { desc = "LSP: Rename" })
      vim.keymap.set("n", "gra", vim.lsp.buf.code_action, { desc = "LSP: Code action" })
      vim.keymap.set("n", "gd", vim.lsp.buf.definition, { desc = "LSP: Goto definition" })
      vim.keymap.set("n", "gri", vim.lsp.buf.implementation, { desc = "LSP: Go to implementation" })
      vim.keymap.set("n", "<leader>D", vim.lsp.buf.type_definition, { desc = "LSP: Type definition" })
      vim.keymap.set("n", "gO", vim.lsp.buf.document_symbol, { desc = "LSP: Document symbols" })
      vim.keymap.set("n", "<leader>ds", function() Snacks.picker.lsp_symbols() end, { desc = "LSP: Document symbols" })
      vim.keymap.set("n", "<leader>ws", function() Snacks.picker.lsp_workspace_symbols() end,
        { desc = "LSP: Workspace symbols" })
      vim.keymap.set("n", "K", vim.lsp.buf.hover, { desc = "LSP: Hover documentation" })
      vim.keymap.set("n", "<C-k>", vim.lsp.buf.signature_help, { desc = "LSP: Signature help" })
      vim.keymap.set("n", "gD", vim.lsp.buf.declaration, { desc = "LSP: Goto declaration" })
      vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action, { desc = "LSP: Code actions (verbose)" })

      vim.keymap.set("n", "<leader>wa", vim.lsp.buf.add_workspace_folder, { desc = "LSP: Add workspace folder" })
      vim.keymap.set("n", "<leader>wr", vim.lsp.buf.remove_workspace_folder, { desc = "LSP: Remove workspace folder" })
      vim.keymap.set("n", "<leader>wl", function() print(vim.inspect(vim.lsp.buf.list_workspace_folders())) end,
        { desc = "LSP: List workspace folders" })

      -- Diagnostics configuration
      vim.diagnostic.config({
        signs = {
          text = {
            [vim.diagnostic.severity.ERROR] = " ",
            [vim.diagnostic.severity.WARN] = " ",
            [vim.diagnostic.severity.INFO] = " ",
            [vim.diagnostic.severity.HINT] = " ",
          },
        },
        virtual_text = {
          prefix = "●",
          spacing = 4,
        },
        underline = true,
        update_in_insert = false,
        severity_sort = true,
      })

      -- LSP attach handler
      vim.api.nvim_create_autocmd('LspAttach', {
        group = vim.api.nvim_create_augroup('UserLspConfig', {}),
        callback = function(ev)
          local client = vim.lsp.get_client_by_id(ev.data.client_id)
          local bufnr = ev.buf

          vim.bo[bufnr].omnifunc = 'v:lua.vim.lsp.omnifunc'

          local opts = { buffer = bufnr }
          vim.keymap.set('n', '<leader>rn', vim.lsp.buf.rename, opts)
          vim.keymap.set('n', '<leader>ca', vim.lsp.buf.code_action, opts)

          if client then
            if client.server_capabilities.documentHighlightProvider then
              vim.api.nvim_create_autocmd({ 'CursorHold', 'CursorHoldI' }, {
                buffer = bufnr,
                callback = vim.lsp.buf.document_highlight,
              })
              vim.api.nvim_create_autocmd('CursorMoved', {
                buffer = bufnr,
                callback = vim.lsp.buf.clear_references,
              })
            end
          end
        end,
      })
    end
  },
  {
    "j-hui/fidget.nvim",
    tag = "legacy",
    event = "LspAttach",
    config = function()
      require("fidget").setup()
    end
  },
  {
    "hrsh7th/cmp-nvim-lsp",
    event = "InsertEnter",
  },
  {
    "onsails/lspkind.nvim",
    event = "InsertEnter",
  },
  {
    "stevearc/conform.nvim",
    event = { "BufWritePre" },
    cmd = { "ConformInfo" },
    config = function()
      require("conform").setup({
        timeout_ms = 10000,
        formatters_by_ft = {
          lua = { "stylua" },
          python = { "isort", "black" },
          javascript = { "prettier" },
          json = { "prettier" },
          html = { "prettier" },
          rust = { "rustfmt" },
        },
      })

      vim.api.nvim_buf_create_user_command(0, "Format", function()
        require("conform").format()
      end, { desc = "LSP: Format current buffer" })

      vim.keymap.set("n", "<leader>fm", function()
        require("conform").format()
        vim.cmd "w"
        print "Formatted and Saved"
      end, { desc = "Format and Save File" })
    end
  }
}
