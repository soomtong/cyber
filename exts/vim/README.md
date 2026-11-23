## Manual Install.

```sh
git clone https://github.com/fubark/cyber.git
mkdir -p ~/.vim/pack/plugins/start
ln -s `pwd`/exts/vim ~/.vim/pack/plugins/start/cyber
```

Recommended `~/.vimrc` options.
```vim
set tabstop=4
set shiftwidth=4
set expandtab
syntax on
filetype indent on
```
## Neovim

The plugin above also works in Neovim (link it into `~/.config/nvim/pack/plugins/start/cyber`).
It gives the filetype, regex syntax highlighting and indent.

The setup below does not need the plugin. It uses the language server and the
tree-sitter grammar instead, and was checked with Neovim 0.12.

### Filetype

Neovim does not know `.cy` files. Register the filetype early, before any lazy loaded plugin.

```lua
vim.filetype.add { extension = { cy = 'cyber' } }

vim.api.nvim_create_autocmd('FileType', {
  pattern = 'cyber',
  callback = function()
    vim.bo.commentstring = '-- %s'
  end,
})
```

### Language server

`cyber-lsp` must be in `PATH`. It is not in the Mason registry or in nvim-lspconfig,
so define it with the built in `vim.lsp.config` (Neovim 0.11 or later).

```lua
vim.lsp.config('cyber', {
  cmd = { 'cyber-lsp' },
  filetypes = { 'cyber' },
  root_markers = { '.git' },
})
vim.lsp.enable 'cyber'
```

In NvChad, put this in `lua/configs/lspconfig.lua` and add `cyber` to the `servers` list.
Completion then comes from nvim-cmp. Without a completion plugin, turn on the built in one:

```lua
vim.api.nvim_create_autocmd('LspAttach', {
  callback = function(args)
    local client = assert(vim.lsp.get_client_by_id(args.data.client_id))
    if client:supports_method 'textDocument/completion' then
      vim.lsp.completion.enable(true, client.id, args.buf, { autotrigger = true })
    end
  end,
})
```

### Tree-sitter highlighting

The grammar is in [exts/tree-sitter](../tree-sitter). Register it with the `main` branch
of nvim-treesitter. `parser.c` is not committed, so the install generates it and needs
the `tree-sitter` CLI and a C compiler.

```lua
-- Must run before nvim-treesitter loads, with lazy.nvim put it in `init`.
vim.api.nvim_create_autocmd('User', {
  pattern = 'TSUpdate',
  callback = function()
    require('nvim-treesitter.parsers').cyber = {
      install_info = {
        url = 'https://github.com/soomtong/cyber',
        branch = 'master',
        location = 'exts/tree-sitter',
        generate = true,
        generate_from_json = false,
        -- Relative to the repository root, not to `location`.
        queries = 'exts/tree-sitter/queries',
      },
    }
  end,
})
```

Then run `:TSInstall cyber`, or add `cyber` to `ensure_installed`. No revision is pinned,
so `:TSUpdate` does not see a grammar change. Run `:TSInstall! cyber` to fetch it again.

To work on the grammar from a local checkout, replace `url` and `branch` with `path`.
The queries are then linked instead of copied.

```lua
install_info = {
  path = '~/path/to/cyber',
  location = 'exts/tree-sitter',
  generate = true,
  generate_from_json = false,
  queries = 'exts/tree-sitter/queries',
},
```

The `main` branch does not start highlighting by itself. NvChad already does it, otherwise add:

```lua
vim.api.nvim_create_autocmd('FileType', {
  pattern = 'cyber',
  callback = function()
    vim.treesitter.start()
  end,
})
```
