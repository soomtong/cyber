use cy

--| Related to the command line.
--| Sample usage:
--| ```cy
--| use cli
--| cli.repl()
--| ```

--| Starts a REPL session that reads from the terminal.
--| The session runs in its own VM, made by `new_vm()`: it imports what a script run by `cyber` imports.
fn repl() -> void:
    ctx := cy.REPL.new(new_vm())
    ctx.doc_fn = repl_doc
    ctx.run(repl_read_line_)

--| Creates a VM that imports what a script run by `cyber` imports: the standard modules of the CLI (`os`, `cli`,
--| `libc`), files and urls. Its values, globals and types are its own. `cy.VM()` creates a VM that has the
--| modules of the library only.
fn new_vm() -> cy.VM:
    vm := cy.VM()
    use_cli_modules(vm.inner)
    return vm

-- Gives `vm` (a `cy.VM.inner`) the resolver, the loader and the user data of the CLI.
#[bind] -fn use_cli_modules(vm Ptr[void]) -> void

--| Prints what `cyber doc <query>` prints: a section of the manual, the topics for an empty query, or the
--| functions of a module for `--api <module>`. This is the command `.doc` of the REPL.
#[bind] fn repl_doc(query str) -> void

--| Default implementation to read a line from the CLI for a REPL.
#[bind] fn repl_read_line(prefix str) -> str

fn repl_read_line_(prefix str) -> Future[str]:
    line := repl_read_line(prefix)
    return Future.complete(line)