# Extensions

## Language server

* `cyber-lsp` in this repository (`zig build lsp`, sources in `src/lsp`). Diagnostics, formatting, outline and folding
  over the Language Server Protocol. Design and stages: `docs/specs/2026-11-12-lsp-design.md`.

## VS Code

* [vscode](./vscode) Syntax highlighting and the client of `cyber-lsp`. See its README to install.

* [cyber-vscode](https://github.com/daelonsuzuka/cyber-vscode), [Marketplace](https://marketplace.visualstudio.com/items?itemName=DaelonSuzuka.cyber) by @daelonsuzuka

## Vim and Neovim

* [cyber.nvim](https://github.com/soomtong/cyber.nvim) Neovim plugin for the current syntax: filetype, the client of
  `cyber-lsp`, tree-sitter highlighting and indent. It carries a copy of the grammar in [tree-sitter](./tree-sitter).
* [vim](./vim) Filetype, regex syntax highlighting and indent for Vim.
* [nvim-cyber](https://github.com/instance-id/nvim-cyber) by @instance-id. For the 2023 syntax.

## Tree-sitter

* [tree-sitter](./tree-sitter) Grammar for the current syntax. See its README to build.
* [tree-sitter-cyber](https://github.com/instance-id/tree-sitter-cyber) by @instance-id. Earlier grammar for the 2023 syntax. The grammar in this folder is a rewrite of it.
