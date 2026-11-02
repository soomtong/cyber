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

Register the parser with nvim-treesitter and copy the queries:

```lua
local parsers = require('nvim-treesitter.parsers').get_parser_configs()
parsers.cyber = {
  install_info = {
    url = '/path/to/cyber/exts/tree-sitter',
    files = { 'src/parser.c', 'src/scanner.c' },
    requires_generate_from_grammar = true,
  },
  filetype = 'cyber',
}
vim.filetype.add({ extension = { cy = 'cyber' } })
```

```sh
mkdir -p ~/.config/nvim/queries/cyber
cp queries/*.scm ~/.config/nvim/queries/cyber/
```

## Coverage

All `.cy` files in this repository (333 files) were parsed. 311 parse without an
error node. The other 22 are tests that expect a parse error (`*_error.cy`,
`src/test/syntax/`) or files that still use the old syntax (`var a = 1`, `func`).

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
