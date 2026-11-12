use t 'test'
use cy
use meta

-- eval()
res := cy.eval('''
fn main() -> int:
    return 1
''')!
t.eq(1, res.downcast(^int).*)

res = cy.eval('''
fn main() -> int:
    return 1 + 2
''')!
t.eq(3, res.downcast(^int).*)

res = cy.eval('''
fn mul(a int, b int) -> int:
    return a * b
fn main() -> int:
    return mul(10, 5)
''')!
t.eq(50, res.downcast(^int).*)

res = cy.eval(```
fn main() -> str:
    return "hello %{123}"
```)!
t.eq('hello 123', res.downcast(^str).*)
t.eq(error.EvalError, cy.eval('a').unwrap_error())

-- A heap source string is released by the host `VM.eval` (no unreleased refcount).
res = cy.eval('fn main() -> int:\n    return ' + '7')!
t.eq(7, res.downcast(^int).*)

-- parse()
fn parseStmts(src str) -> []^cy.Node:
    res := cy.parse(src)
    return res.root.?.!root.stmts

-- A syntax error is logged, and the result has no root.
t.eq(cy.parse('a := (1 +').root == none, true)
t.eq(cy.parse("s := 'abc").root == none, true)

stmts := parseStmts('global foo int = 123')
t.eq(cy.Node.Tag.global_decl, meta.choice_tag(stmts[0].*))
t.eq('foo', stmts[0].!global_decl.name.name())

stmts = parseStmts('type foo = bar')
t.eq(cy.Node.Tag.type_alias_decl, meta.choice_tag(stmts[0].*))
t.eq('foo', stmts[0].!type_alias_decl.name.name())

stmts = parseStmts('fn foo(): pass')
t.eq(cy.Node.Tag.func_decl, meta.choice_tag(stmts[0].*))
t.eq('foo', stmts[0].!func_decl.name.name())

stmts = parseStmts('fn Foo :: foo(): pass')
t.eq(cy.Node.Tag.func_decl, meta.choice_tag(stmts[0].*))
t.eq('Foo', stmts[0].!func_decl.parent.?.name())
t.eq('foo', stmts[0].!func_decl.name.name())

stmts = parseStmts("use foo 'bar'")
t.eq(cy.Node.Tag.import_stmt, meta.choice_tag(stmts[0].*))
t.eq('foo', stmts[0].!import_stmt.name.name())

stmts = parseStmts("type foo:\n  a int")
t.eq(cy.Node.Tag.struct_decl, meta.choice_tag(stmts[0].*))
t.eq('foo', stmts[0].!struct_decl.name.name())

stmts = parseStmts("type foo struct:\n  a int")
t.eq(cy.Node.Tag.struct_decl, meta.choice_tag(stmts[0].*))
t.eq('foo', stmts[0].!struct_decl.name.name())

stmts = parseStmts("type foo enum:\n  case a int")
t.eq(cy.Node.Tag.enum_decl, meta.choice_tag(stmts[0].*))
t.eq('foo', stmts[0].!enum_decl.name.name())

-- REPL.read()
-- Lines are served from a script; `.exit` ends the session.
global repl_lines []str = {}
global repl_pos int = 0
global repl_prefixes []str = {}
fn repl_read(prefix str) -> Future[str]:
    repl_prefixes = repl_prefixes + prefix
    line := repl_lines[repl_pos]
    repl_pos += 1
    return Future.complete(line)

repl := cy.REPL.new()

-- A plain line is submitted as is.
repl_lines = []str{'a := 1', '.exit'}
repl_pos = 0
t.eq('a := 1', repl.read(repl_read).?)
t.eq(?str(none), repl.read(repl_read))

-- A block is submitted on the empty line that closes it. Nested blocks keep their own line and indentation.
repl_lines = []str{'fn f():', 'if true:', 'print(1)', '', '', '.exit'}
repl_pos = 0
repl_prefixes = []str{}
t.eq("fn f():\n    if true:\n        print(1)", repl.read(repl_read).?)
t.eq(?str(none), repl.read(repl_read))
t.eq_slice([]str{'> ', '    | ', '        | ', '        | ', '    | ', '> '}, repl_prefixes)

-- An attribute line is held until the declaration it annotates is complete.
repl_lines = []str{'#[inline]', 'fn g() -> int:', 'return 1', '', '.exit'}
repl_pos = 0
repl_prefixes = []str{}
t.eq("#[inline]\nfn g() -> int:\n    return 1", repl.read(repl_read).?)
t.eq(?str(none), repl.read(repl_read))
t.eq_slice([]str{'> ', '| ', '    | ', '    | ', '> '}, repl_prefixes)

-- An attribute on a one line declaration is submitted by an empty line.
repl_lines = []str{'#[bind] fn foo() -> int', '', '.exit'}
repl_pos = 0
t.eq("#[bind] fn foo() -> int", repl.read(repl_read).?)
t.eq(?str(none), repl.read(repl_read))

--cytest: pass
