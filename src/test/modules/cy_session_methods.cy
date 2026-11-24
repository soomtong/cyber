use t 'test'
use cy

-- F-199. A later eval of a `persist_main` session declares a method or a member for a type that an earlier
-- eval declared. It used to abort the host: 'attempt to use null value' in `module.reserveFunc`.

-- Evals `src` in the session. Returns the description of the result, or the first line of the compile error.
fn run(vm &cy.VM, src str) -> str:
    res := vm.eval('eval', src, {persist_main=true})
    if res.code == cy.Success:
        return vm.value_desc(res.val_t, res.value)
    summary := vm.compile_error_summary()
    return summary[0..summary.index("\n").?]

vm := cy.VM()
t.eq('', run(&vm, '''
type V:
    x float
fn helper(a float) -> float:
    return a + 100
v := V{x=2}
'''))

-- A method and a type function.
t.eq('', run(&vm, '''
fn (&V) twice() -> float:
    return helper(self.x * 2)
'''))
t.eq('`float` 104.0', run(&vm, 'v.twice()'))
t.eq('', run(&vm, '''
fn V :: make() -> V:
    return V{x=1}
'''))
t.eq('`float` 102.0', run(&vm, 'V.make().twice()'))

-- The body sees the input that declares it: a function declared after it in the same input.
t.eq('', run(&vm, '''
fn (&V) later() -> float:
    return after(self.x)
fn after(a float) -> float:
    return a - 1
'''))
t.eq('`float` 1.0', run(&vm, 'v.later()'))

-- A constant and a function template of the type.
t.eq('', run(&vm, '''
const V :: K = 7
fn V :: gen[T Any](x T) -> T:
    return x
'''))
t.eq('`int` 10', run(&vm, 'V.K + V.gen[int](3)'))

-- An overload is added. The methods of the earlier inputs stay.
t.eq('', run(&vm, '''
fn (&V) twice(n int) -> float:
    return self.x * 2 * float(n)
'''))
t.eq('`float` 116.0', run(&vm, 'v.twice() + v.twice(3)'))

-- The same signature is an error, like in one source. So is an overload that differs in the return type only,
-- also from a method that was the only one of its name when it was declared.
t.eq('CompileError: `twice` has already been declared with the same function signature.', run(&vm, '''
fn (&V) twice() -> float:
    return 0
'''))
t.eq('CompileError: `twice` has already been declared with the same parameters. Overloads must differ in their parameter types, not only in the return type.', run(&vm, '''
fn (&V) twice(n int) -> int:
    return 0
'''))
t.eq('CompileError: `later` has already been declared with the same parameters. Overloads must differ in their parameter types, not only in the return type.', run(&vm, '''
fn (&V) later() -> int:
    return 0
'''))
t.eq('`float` 117.0', run(&vm, 'v.twice() + v.twice(3) + v.later()'))

-- A failed input leaves nothing in the type: the method is not there, and it can be declared again.
t.eq('CompileError: Undeclared variable `nosuch`.', run(&vm, '''
fn (&V) half() -> float:
    return nosuch
'''))
t.eq('CompileError: Can not find the symbol `half` in `V`.', run(&vm, 'v.half()'))
t.eq('CompileError: Undeclared variable `nosuch`.', run(&vm, '''
fn (&V) twice(a float, b float) -> float:
    return nosuch
'''))
t.eq('`float` 116.0', run(&vm, 'v.twice() + v.twice(3)'))
t.eq('', run(&vm, '''
fn (&V) half() -> float:
    return self.x / 2
fn (&V) twice(a float, b float) -> float:
    return self.x * a * b
'''))
t.eq('`float` 13.0', run(&vm, 'v.half() + v.twice(2.0, 3.0)'))

-- A private method of a later input is visible to the session, which is one module.
t.eq('', run(&vm, '''
-fn (&V) hidden() -> float:
    return self.x
'''))
t.eq('`float` 2.0', run(&vm, 'v.hidden()'))

-- A panic drops the locals and keeps the methods.
t.assert(vm.eval('eval', "panic('boom')", {persist_main=true}).code == cy.ErrorPanic)
t.eq('`float` 104.0', run(&vm, '''
v := V{x=2}
v.twice()
'''))

-- `VM.which` compiles without running, under another uri. What its source declares is not kept.
-- (It answers for an expression. Given a source with declarations, the test only looks at whether it compiled.)
t.eq("fn (&V) twice(n int) -> float\n  one of 3 overloads\n  at eval:2:1", vm.which('v.twice(3)'))
t.assert(!vm.which('''
fn (&V) third() -> float:
    return self.x / 3
v.third()''').contains('Error:'))
t.eq('CompileError: Can not find the symbol `third` in `V`.', run(&vm, 'v.third()'))
t.eq('', run(&vm, '''
fn (&V) third() -> float:
    return self.x * 30
'''))
t.eq('`float` 60.0', run(&vm, 'v.third()'))

-- The `@` methods that change how the values of the type are destroyed, copied and sent are not accepted.
t.eq('CompileError: Can not declare `@deinit` for `V` after the input that declares `V`. The code that the session compiled since then destroys, copies and sends a `V` without it. Declare the type again, together with `@deinit`.', run(&vm, '''
fn (&V) @deinit():
    pass
'''))
t.assert(run(&vm, '''
fn (&V) @copy() -> V:
    return V{x=0}
''').starts_with('CompileError: Can not declare `@copy` for `V` after the input that declares `V`.'))
-- The other `@` methods are found where they are used.
t.eq('', run(&vm, '''
fn (&V) @index(i int) -> float:
    return self.x + float(i)
'''))
t.eq('`float` 6.0', run(&vm, 'v[4]'))

-- What is not a type of the session.
t.eq('', run(&vm, '''
use math
type Num = int
global g int = 3
'''))
t.eq('CompileError: Can not declare `sub` for `helper`: `helper` is not a type. A method `fn (&T) name()` or a member `fn T :: name()` is declared for a type of this module.', run(&vm, '''
fn helper :: sub() -> int:
    return 2
'''))
t.assert(run(&vm, '''
fn (&g) sub() -> int:
    return 2
''').starts_with('CompileError: Can not declare `sub` for `g`: `g` is not a type.'))
t.eq('CompileError: Can not declare `sub` for `math`: `math` belongs to another module. A method or a member of a type is declared in the module that declares the type.', run(&vm, '''
fn math :: sub() -> int:
    return 2
'''))
t.eq('CompileError: Cannot declare from type alias.', run(&vm, '''
fn (&Num) sub() -> int:
    return 2
'''))
t.eq('CompileError: Undeclared symbol: `Nope`', run(&vm, '''
fn (&Nope) sub() -> int:
    return 2
'''))

-- A type that is declared again takes the methods that follow. The values of the first type keep theirs.
t.eq('', run(&vm, '''
type V:
    y int
fn (&V) twice() -> int:
    return self.y * 2
v2 := V{y=4}
'''))
t.eq('', run(&vm, '''
fn (&V) more() -> int:
    return self.y + 1
'''))
t.eq('`int` 13', run(&vm, 'v2.twice() + v2.more()'))
t.eq('`float` 104.0', run(&vm, 'v.twice()'))
t.eq('CompileError: Can not find the symbol `more` in `V`.', run(&vm, 'v.more()'))

-- Enum and choice types.
vm = cy.VM()
t.eq('', run(&vm, '''
type Color enum:
    case red
    case green
type Shape enum:
    case circle float
    case square float
c := Color.green
s := Shape.circle(2.0)
'''))
t.eq('', run(&vm, '''
fn (&Color) is_red() -> bool:
    return self.* == Color.red
fn (&Shape) area() -> float:
    switch self.*:
        case .circle |r|: return r * r * 3.0
        case .square |w|: return w * w
'''))
t.eq('`bool` false', run(&vm, 'c.is_red()'))
t.eq('`float` 12.0', run(&vm, 's.area()'))

-- A type with a trait: another method and an overload of a trait method are added. A method with the signature of a
-- default method that the type got is a duplicate.
t.eq('', run(&vm, '''
type Named trait:
    fn name() -> str
    fn hello() -> str:
        return 'hello ' + self.name()
type P:
    with Named
    n int
fn (&P) name() -> str:
    return 'p'
p := P{n=1}
'''))
t.eq('', run(&vm, '''
fn (&P) loud() -> str:
    return self.hello() + '!'
fn (&P) hello(n int) -> str:
    return 'hi'
'''))
t.eq("`str` 'hello p!hi'", run(&vm, 'p.loud() + p.hello(1)'))
t.eq('CompileError: `hello` has already been declared with the same function signature.', run(&vm, '''
fn (&P) hello() -> str:
    return 'x'
'''))
t.eq("`str` 'hello p'", run(&vm, 'p.hello()'))

-- A template type.
vm = cy.VM()
t.eq('', run(&vm, '''
type Box[T Any]:
    val T
b := Box[int]{val=3}
'''))
-- A new method reaches the instance that an earlier input made.
t.eq('', run(&vm, '''
fn (&Box[]) get() -> T:
    return self.val
'''))
t.eq('`int` 3', run(&vm, 'b.get()'))
-- An overload reaches the instance that expanded the method before, and a new instance.
t.eq('', run(&vm, '''
fn (&Box[]) get(add T) -> T:
    return self.val + add
'''))
t.eq('`int` 10', run(&vm, 'b.get(4) + b.get()'))
t.eq('`float` 4.0', run(&vm, '''
f := Box[float]{val=1.5}
f.get(1.0) + f.get()
'''))
-- A failed input: the overload leaves the template and the instances that expanded it.
t.eq('CompileError: Undeclared variable `nosuch`.', run(&vm, '''
fn (&Box[]) get(a T, b2 T) -> T:
    return nosuch
b.get(1, 2)
'''))
t.assert(run(&vm, 'b.get(1, 2)').starts_with('CompileError: Expected `1` arguments, found `3`'))
t.eq('`int` 10', run(&vm, 'b.get(4) + b.get()'))
t.eq('`int` 6', run(&vm, '''
fn (&Box[]) get(a T, b2 T) -> T:
    return self.val + a + b2
b.get(1, 2)
'''))
-- A duplicate is an error of the input that declares it when an instance has expanded the method.
t.eq('CompileError: `get` has already been declared with the same function signature.', run(&vm, '''
fn (&Box[]) get() -> T:
    return self.val
'''))
t.eq('`int` 3', run(&vm, 'b.get()'))
-- A type function and a constant of the template.
t.eq('', run(&vm, '''
fn Box[] :: make(v T) -> Box[T]:
    return Box[T]{val=v}
const Box[] :: zero = 0
'''))
t.eq('`int` 9', run(&vm, 'Box[int].make(9).get() + Box[int].zero'))
t.assert(run(&vm, '''
fn (&Box[]) @deinit():
    pass
''').starts_with('CompileError: Can not declare `@deinit` for `Box` after the input that declares `Box`.'))

-- A source that is only checked (`VM.which`) declares a method that code of earlier templates calls. The
-- instances that it expanded are not kept with a call to the method: they are expanded again. That goes for a
-- body that reaches the method through another instance or from a lambda.
vm = cy.VM()
t.eq('', run(&vm, '''
type V:
    x float
    name str
type Box[T Any]:
    val T
fn (&Box[]) show() -> float:
    return self.val.twice()
fn (&Box[]) apply() -> float:
    f := fn(x float) => x + self.val.twice()
    return f(1.0)
fn dbl(x %T) -> float:
    return x.twice()
fn outer(x %T) -> float:
    return dbl(x) + 1
v := V{x=2, name='n'}
b := Box[V]{val=v}
'''))
t.assert(!vm.which('''
fn (&V) twice() -> float:
    return self.x * 2
vs := []V{v}
ws := vs + []V{V{x=1, name='m'}}
_ = b.apply() + ws[0].twice()
outer(v)''').contains('Error:'))
t.eq('CompileError: Can not find the symbol `twice` in `V`.', run(&vm, 'outer(v)'))
t.eq('CompileError: Can not find the symbol `twice` in `V`.', run(&vm, 'b.apply()'))
-- An instance that does not reach the method is kept and works: `[]V` and what destroys it.
t.eq('`int` 2', run(&vm, '''
vs := []V{v}
ws := vs + []V{V{x=1, name='m'}}
ws.len()
'''))
t.assert(!vm.which('''
fn (&V) twice() -> float:
    return self.x * 2
dbl(v)''').contains('Error:'))
t.eq('CompileError: Can not find the symbol `twice` in `V`.', run(&vm, 'dbl(v)'))
t.assert(!vm.which('''
fn (&V) twice() -> float:
    return self.x * 2
b.show()''').contains('Error:'))
t.eq('CompileError: Can not find the symbol `twice` in `V`.', run(&vm, 'b.show()'))
t.eq('', run(&vm, '''
fn (&V) twice() -> float:
    return self.x * 3
'''))
t.eq('`float` 18.0', run(&vm, 'dbl(v) + b.show() + v.twice()'))
t.eq('`float` 14.0', run(&vm, 'outer(v) + b.apply()'))

--cytest: pass
