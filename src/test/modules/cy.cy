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

-- A command is run by `read` where an input starts and is not returned as code. `.doc` without a host hook
-- says so. Inside a block the same text is a line of the block.
repl_lines = []str{'.doc optionals', '.which', '.bc', 'b := 2', '.exit'}
repl_pos = 0
t.eq('b := 2', repl.read(repl_read).?)
t.eq(?str(none), repl.read(repl_read))
repl_lines = []str{'if true:', '.bc', '', '.exit'}
repl_pos = 0
t.eq("if true:\n    .bc", repl.read(repl_read).?)
t.eq(?str(none), repl.read(repl_read))
t.eq(false, repl.command('x := 1'))
t.eq(false, repl.command('.red'))

-- VM.which(): the function that a call picks, without running it.
vm := cy.VM()
session := ```
fn sq(x int) -> int:
    return x * x

fn largest(a %T, b T) -> T:
    return if (a > b) a else b

fn show(x float) -> str:
    return 'float'

--| Shows an int.
--| The second line.
fn show(n int) -> str:
    return 'int'

global ran int = 0

fn count() -> int:
    ran += 1
    return ran

n := 3
```
t.eq(cy.Success, vm.eval('eval', session, {persist_main=true}).code)

t.eq("fn sq(x int) -> int\n  at eval:2:1", vm.which('sq(n)'))
-- The outermost call.
t.eq("fn sq(x int) -> int\n  at eval:2:1", vm.which('sq(count())'))
-- An overload, with its doc comment.
t.eq("fn show(n int) -> str\n  one of 2 overloads\n  at eval:13:1\n  Shows an int.\n  The second line.", vm.which('show(n)'))
t.eq("fn show(x float) -> str\n  one of 2 overloads\n  at eval:8:1", vm.which('show(2.5)'))
-- An instance of a template.
t.eq("fn largest(a %T, b T) -> T\n  as fn largest[int](int, int) -> int\n  at eval:5:1", vm.which('largest(n, 9)'))
t.eq("fn largest(a %T, b T) -> T\n  as fn largest[float](float, float) -> float\n  at eval:5:1", vm.which('largest(1.5, 2.5)'))
-- A method of a core type.
t.assert(vm.which("'abc'.upper()").starts_with("fn (&str) upper() -> str\n  at core:"))
-- Without a call: the name at the end.
t.eq('n int', vm.which('n'))
t.eq("fn sq(x int) -> int\n  at eval:2:1", vm.which('sq'))
-- A compile error is the answer.
t.assert(vm.which('nosuch(1)').starts_with('CompileError: Undeclared variable `nosuch`.'))
t.assert(vm.which('sq(').starts_with('ParseError:'))

-- Nothing ran, and the session goes on.
check := vm.eval('eval', 'ran', {persist_main=true})
t.eq(cy.Success, check.code)
t.eq('`int` 0', vm.value_desc(check.val_t, check.value))
t.eq(cy.Success, vm.eval('eval', 'm := sq(n) + count()', {persist_main=true}).code)
t.eq("fn sq(x int) -> int\n  at eval:2:1", vm.which('sq(m)'))

-- VM.bytecode(): the compiled functions of a name.
bc := vm.bytecode('sq')
t.assert(bc.starts_with("fn sq(int) -> int  (eval)\n"))
t.assert(bc.contains('.ret'))
t.assert(!bc.contains('fn largest'))
-- Every instance of a template that a call made.
bc = vm.bytecode('largest')
t.assert(bc.contains('fn largest[int](int, int) -> int'))
t.assert(bc.contains('fn largest[float](float, float) -> float'))
-- Every overload.
bc = vm.bytecode('show')
t.assert(bc.contains('fn show(float) -> str'))
t.assert(bc.contains('fn show(int) -> str'))
t.eq('', vm.bytecode('nosuch'))

--cytest: pass
