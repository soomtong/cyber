# tree-sitter-cyber

Tree-sitter grammar for Cyber 0.4 (the `soomtong/cyber` fork). The rules follow
`src/tokenizer.zig` and `src/parser.zig` of this repository.

## Origin

The earlier [tree-sitter-cyber](https://github.com/instance-id/tree-sitter-cyber) by
@instance-id targets the 2023 syntax (`func`, `var x = 1`, `import`, `object`). That
repository declares the MIT license in `Cargo.toml` and has no `LICENSE` file. This
grammar is a rewrite for the current syntax. It keeps the same project layout: an
external indentation scanner, `queries/highlights.scm`, `locals.scm` and `tags.scm`.
Both copyright notices are in `LICENSE`.

## Files

| Path | Content |
| --- | --- |
| `grammar.js` | Grammar rules |
| `src/scanner.c` | External scanner. Emits NEWLINE, INDENT and DEDENT. |
| `queries/*.scm` | Highlights, locals, tags and indents |
| `test/corpus/*.txt` | Parse tests |
| `tree-sitter.json` | Language metadata (`*.cy`, scope `source.cyber`) |

`src/parser.c` is about 12 MB and is not committed. Generate it before you build.

## Build

Requires `tree-sitter` CLI 0.25 or later.

```sh
cd exts/tree-sitter
tree-sitter generate
tree-sitter test
tree-sitter build            # writes cyber.dylib / cyber.so
tree-sitter build --wasm     # writes tree-sitter-cyber.wasm
```

Parse a file:

```sh
tree-sitter parse ../../examples/account.cy
tree-sitter highlight --scope source.cyber ../../examples/account.cy
```

## Neovim

Register the parser with the `main` branch of nvim-treesitter. The `master` branch
(`get_parser_configs`) does not support Neovim 0.12. The install generates `parser.c`
and copies the queries, so it needs the `tree-sitter` CLI and a C compiler.

```lua
vim.filetype.add { extension = { cy = 'cyber' } }

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

Then run `:TSInstall cyber`. No revision is pinned, so `:TSUpdate` does not see a
grammar change. Run `:TSInstall! cyber` to fetch it again.

To work on the grammar from a local checkout, replace `url` and `branch` with
`path = '~/path/to/cyber'`. The queries are then linked instead of copied.

See [exts/vim/README.md](../vim/README.md#neovim) for how to start the highlighting
and for the `cyber-lsp` setup.

## Coverage

Every `.cy` file in this repository that the compiler parses (417 files, checked
with `cyber fmt --check`) parses without an error node. The remaining 28 files are
tests that expect a parse error (`*_error.cy`, `src/test/syntax/`) or files that
still use the old syntax (`var a = 1`, `func`). Last checked for Cyber 0.4.6.

Known differences from the compiler parser:

- A lone identifier in a parameter list is read as a parameter name. In
  `fn(int) -> bool` the `int` is a name, not a type.
- Call arguments must be separated by commas. The compiler also accepts a line
  end as a separator.
- A single statement after `:` inside an expression (lambda body, `?else:`,
  `!else:`) can only be `return`, `break`, `continue`, `pass`, `yield`, an
  expression or an assignment. The compiler accepts any statement there.
- `-` directly before `fn`, `type`, `const`, `global` or `use` at the start of a
  statement is always read as visibility, like the compiler.
