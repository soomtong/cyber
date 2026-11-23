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

Use [cyber.nvim](https://github.com/soomtong/cyber.nvim). It needs Neovim 0.12 or later and gives the
filetype, the `cyber-lsp` client, tree-sitter highlighting, indent and `:checkhealth cyber`.

With lazy.nvim:

```lua
{ 'soomtong/cyber.nvim', ft = 'cyber' }
```

No setup call is needed.

- `cyber-lsp` must be in `PATH`. Without it the server is not started.
- The plugin builds the tree-sitter parser on the first Cyber buffer. That needs the `tree-sitter` CLI
  and a C compiler. nvim-treesitter is not needed.

Options, completion and folding are in the README of the plugin.

The Vim plugin of this folder also works in Neovim (link it into `~/.config/nvim/pack/plugins/start/cyber`).
It gives the filetype, regex syntax highlighting and indent only. Do not use both.
