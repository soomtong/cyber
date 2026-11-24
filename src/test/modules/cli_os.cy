use t 'test'
use cli
use cy

-- The REPL of the CLI imports `os` (F-200). `os` calls libc through extern functions, so this needs FFI.
global lines []str = {}
global pos int = 0
fn read(prefix str) -> Future[str]:
    line := lines[pos]
    pos += 1
    return Future.complete(line)

repl := cy.REPL.new(cli.new_vm())
lines = []str{'use os', 'cwd := os.cwd()!', 'use math', 'root := math.sqrt(4.0)', 'again := os.cwd()!', '.exit'}
repl.run(read)
res := repl.vm.eval('eval', 'cwd.len() > 0 and cwd == again', {persist_main=true})
t.eq(cy.Success, res.code)
t.eq('`bool` true', repl.vm.value_desc(res.val_t, res.value))
res = repl.vm.eval('eval', 'root', {persist_main=true})
t.eq('`float` 2.0', repl.vm.value_desc(res.val_t, res.value))

-- The session and the script that started it are two VMs: a name of the session is not a name here.
t.eq(cy.ErrorCompile, cy.VM().eval('eval', 'use os', {}).code)

--cytest: pass
