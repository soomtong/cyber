use cy

--| Related to the command line.
--| Sample usage:
--| ```cy
--| use cli
--| cli.repl()
--| ```

--| Starts an isolated REPL session.
--| Invokes `cy.repl(repl_read_line)`.
fn repl() -> void:
    cy.repl(repl_read_line_, repl_doc)

--| Prints what `cyber doc <query>` prints: a section of the manual, the topics for an empty query, or the
--| functions of a module for `--api <module>`. This is the command `.doc` of the REPL.
#[bind] fn repl_doc(query str) -> void

--| Default implementation to read a line from the CLI for a REPL.
#[bind] fn repl_read_line(prefix str) -> str

fn repl_read_line_(prefix str) -> Future[str]:
    line := repl_read_line(prefix)
    return Future.complete(line)