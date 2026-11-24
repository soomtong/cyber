use t 'test'
use cli
use cy

-- cli.new_vm(): a VM that imports what a script run by the CLI imports. `cy.VM()` stays isolated (modules/cy.cy).
vm := cli.new_vm()

-- A module that only the loader of the CLI has.
t.eq(cy.Success, vm.eval('eval', 'use cli', {persist_main=true}).code)
-- A builtin module still loads.
t.eq(cy.Success, vm.eval('eval', 'use math', {persist_main=true}).code)
res := vm.eval('eval', 'math.sqrt(4.0)', {persist_main=true})
t.eq(cy.Success, res.code)
t.eq('`float` 2.0', vm.value_desc(res.val_t, res.value))

-- A file, by a path relative to the working directory: the main chunk of the session is not a file.
t.eq(cy.Success, vm.eval('eval', "use a 'src/test/modules/test_mods/a.cy'", {persist_main=true}).code)
res = vm.eval('eval', 'a.g_int', {persist_main=true})
t.eq(cy.Success, res.code)
t.eq('`int` 123', vm.value_desc(res.val_t, res.value))

-- A missing file is a compile error with the message of the CLI's resolver, and the session goes on.
t.eq(cy.ErrorCompile, vm.eval('eval', "use nosuch 'nosuch.cy'", {persist_main=true}).code)
t.assert(vm.compile_error_summary().starts_with('CompileError: Import path does not exist: `nosuch.cy`'))
t.eq(cy.Success, vm.eval('eval', 'math.sqrt(9.0)', {persist_main=true}).code)

-- `which` compiles against the session with the same imports.
t.assert(vm.which('cli.new_vm()').starts_with("fn new_vm() -> cy.VM\n  at cli:"))

-- A VM made inside the session imports the same: the nested VM shares the settings of the CLI too.
res = vm.eval('eval', "cli.new_vm().eval('eval', 'use cli', {}).code == cy.Success", {persist_main=true})
t.eq(cy.ErrorCompile, res.code)
t.eq(cy.Success, vm.eval('eval', 'use cy', {persist_main=true}).code)
res = vm.eval('eval', "cli.new_vm().eval('eval', 'use cli', {}).code == cy.Success", {persist_main=true})
t.eq(cy.Success, res.code)
t.eq('`bool` true', vm.value_desc(res.val_t, res.value))

-- A REPL of the CLI runs its session in such a VM.
global lines []str = {}
global pos int = 0
fn read(prefix str) -> Future[str]:
    line := lines[pos]
    pos += 1
    return Future.complete(line)

repl := cy.REPL.new(cli.new_vm())
lines = []str{'use cli', 'use path', "base := path.base('a/b.cy')", '.exit'}
repl.run(read)
res = repl.vm.eval('eval', 'base', {persist_main=true})
t.eq(cy.Success, res.code)
t.eq("`str` 'b.cy'", repl.vm.value_desc(res.val_t, res.value))

--cytest: pass
