use t 'test'
use cy

-- Extern functions in a `persist_main` session (F-203). Each eval is a compile of its own.
vm := cy.VM()

-- An eval declares an extern function and calls it.
src := ```
use c
#c.bind_lib(none)

#[extern]
fn getenv(name Ptr[byte]) -> Ptr[byte]

name := c.to_strz('CYBER_NO_SUCH_VAR')
getenv(name) == none
```
res := vm.eval('eval', src, {persist_main=true})
t.eq(cy.Success, res.code)
t.eq('`bool` true', vm.value_desc(res.val_t, res.value))

-- A later eval calls the function that the earlier eval declared. Its call site was not bound and the call
-- jumped to a null address.
res = vm.eval('eval', 'getenv(name) == none', {persist_main=true})
t.eq(cy.Success, res.code)
t.eq('`bool` true', vm.value_desc(res.val_t, res.value))

-- A later eval loads a module with extern functions of its own. The functions of the earlier evals were
-- compiled again into the same TCC state ('defined twice'), which ended the host.
res = vm.eval('eval', "use math\nmath.sqrt(16.0)", {persist_main=true})
t.eq(cy.Success, res.code)
t.eq('`float` 4.0', vm.value_desc(res.val_t, res.value))

-- A later eval declares another extern function. Those of all the earlier evals still run.
src = ```
#[extern]
fn abs(n i32) -> i32

abs(i32(-5)) == i32(5) and getenv(name) == none and math.sqrt(9.0) == 3.0
```
res = vm.eval('eval', src, {persist_main=true})
t.eq(cy.Success, res.code)
t.eq('`bool` true', vm.value_desc(res.val_t, res.value))

-- A variadic extern function: a later eval calls it with a signature that no eval used before, and with one
-- that an earlier eval used.
src = ```
#[extern]
fn snprintf(buf Ptr[byte], size r64, format Ptr[byte], args c.variadic) -> i32

buf := c.to_strz('________')
fmt1 := c.to_strz('%d')
snprintf(buf, 8, fmt1, i32(42))
```
res = vm.eval('eval', src, {persist_main=true})
t.eq(cy.Success, res.code)
t.eq('`i32` 2', vm.value_desc(res.val_t, res.value))
res = vm.eval('eval', "fmt2 := c.to_strz('%d-%d')\nsnprintf(buf, 8, fmt2, i32(1), i32(23))", {persist_main=true})
t.eq(cy.Success, res.code)
t.eq('`i32` 4', vm.value_desc(res.val_t, res.value))
res = vm.eval('eval', 'snprintf(buf, 8, fmt1, i32(7))', {persist_main=true})
t.eq(cy.Success, res.code)
t.eq('`i32` 1', vm.value_desc(res.val_t, res.value))
res = vm.eval('eval', 'c.from_strz(buf)', {persist_main=true})
t.eq("`str` '7'", vm.value_desc(res.val_t, res.value))

-- An eval that fails to compile, then one that calls the extern functions again.
t.eq(cy.ErrorCompile, vm.eval('eval', 'getenv(nosuch)', {persist_main=true}).code)
res = vm.eval('eval', 'abs(i32(-9))', {persist_main=true})
t.eq(cy.Success, res.code)
t.eq('`i32` 9', vm.value_desc(res.val_t, res.value))

--cytest: pass
