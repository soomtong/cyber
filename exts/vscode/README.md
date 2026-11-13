# Cyber for VS Code

Syntax highlighting for `.cy` files and a client for the Cyber language server `cyber-lsp`.

## Features

With the language server running:

* Compile errors as diagnostics while typing. The document is compiled as a program, it is not run.
  Related places (`First declared at:`, the call that expanded a template) are attached to the error.
* Hover: the declaration line of a function or type, the type of a local, a field or an expression.
* Go to Definition, within the document and into the modules it uses.
* Find References and highlights within the document. Rename for locals and parameters.
* Completion: the members after a `.`, and the names in scope. Signature help inside a call.
* Format Document, the same result as `cyber fmt`.
* Outline (types with their fields, functions, methods, constants, globals) and folding by indentation.

The main block and each function show their first error. A syntax error is shown alone until it is fixed.

## Requirements

Build the server from the repository root and put it in `PATH`, or point `cyber.lsp.path` at it:

```bash
zig build lsp -Doptimize=ReleaseSafe
```

The executable is `zig-out/bin/cyber-lsp`. It has to be the same version as the `cyber` that runs the scripts.

## Manual Install

```bash
npm install
```

```bash
npx vsce package
```

Open VS Code, under Extensions click "Install from VSIX..." and pick the generated package.

## Extension Settings

* `cyber.lsp.enabled`: Start the language server. Default `true`.
* `cyber.lsp.path`: Path of the `cyber-lsp` executable. Empty looks up `cyber-lsp` in `PATH`.

The command "Cyber: Restart Language Server" starts the server again, for example after rebuilding it.

## Other editors

`cyber-lsp` speaks the Language Server Protocol over stdin and stdout, so any client can start it.
Neovim (0.11 or later):

```lua
vim.lsp.config('cyber', { cmd = { 'cyber-lsp' }, filetypes = { 'cyber' } })
vim.lsp.enable('cyber')
```
