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
    cy.repl(repl_read_line_)

--| Default implementation to read a line from the CLI for a REPL.
#[bind] fn repl_read_line(prefix str) -> str

fn repl_read_line_(prefix str) -> Future[str]:
    line := repl_read_line(prefix)
    return Future.complete(line)