use test

-- A `!` in an expression lambda with a declared return type returns the error as that type.
f := fn(x str) -> !int => int.parse(x)! + 1
test.eq(3, f('2')!)
test.eq(-1, f('a') !else -1)

-- An inferred return type is the type of the body where nothing leaves the lambda early.
g := fn(x str) => int.parse(x) !else 0
test.eq(2, g('2'))
test.eq(0, g('a'))

-- A `!` that leaves a lambda with an inferred return type makes it `!U`, where `U` is the type of the body.
h := fn(x str) => int.parse(x)!
test.eq(1, h('1')!)
test.eq(error.InvalidCharacter, h('a').unwrap_error())
h2 := fn(x str) => int.parse(x)! + 1
test.eq(3, h2('2')!)
test.eq(-1, h2('a') !else -1)

-- A `!` that the body handles and a `!` that leaves the lambda.
h3 := fn(a str, b str) => (int.parse(a) !else 0) + int.parse(b)!
test.eq(3, h3('q', '3')!)
test.eq(-1, h3('1', 'q') !else -1)

-- A `void` body is `!void`.
fn note(x str) -> !void:
    if x == 'bad':
        return error.Bad
v := fn(x str) => note(x)!
v('ok')!
test.eq(error.Bad, v('bad').unwrap_error())

-- A body that is a `!T` or an `error` already keeps its type.
fn half(x int) -> !int:
    if x % 2 != 0:
        return error.Odd
    return x / 2
k := fn(x str) => half(int.parse(x)!)
test.eq(2, k('4')!)
test.eq(error.Odd, k('3').unwrap_error())
test.eq(error.InvalidCharacter, k('q').unwrap_error())
fn code(x int) -> error:
    return error.Code
k2 := fn(x str) => code(int.parse(x)!)
test.eq(error.Code, k2('1'))
test.eq(error.InvalidCharacter, k2('q'))

-- The values of the body are released on both paths.
fn parts(x str) -> ![]str:
    if x == '':
        return error.Empty
    return []str{x, x}
p := fn(x str) => 'a' + parts(x)![1] + 'b'
test.eq('acb', p('c')!)
test.eq('e', p('') !else 'e')

-- A closure.
base := ^10
m := fn(x str) => int.parse(x)! + base.*
test.eq(12, m('2')!)
test.eq(-1, m('u') !else -1)

-- A lambda that is called at once.
test.eq(4, (fn(x str) => int.parse(x)! + 1)('3')!)

-- The declared and the inferred lambda bind the template parameter of the return type (`U` is `!int`).
fn map(items []%T, f fn(T) -> %U) -> []U:
    out := []U{}
    for items |it|:
        out += f(it)
    return out

res := map([]str{'4', 'b'}, fn(x str) -> !int => int.parse(x)! * 2)
test.eq(8, res[0]!)
test.eq(-1, res[1] !else -1)
res2 := map([]str{'4', 'b'}, fn(x str) => int.parse(x)! * 2)
test.eq(8, res2[0]!)
test.eq(-1, res2[1] !else -1)

-- A lambda in the body infers its own return type.
n := fn(x str) => map([]str{x, '3'}, |y| int.parse(y)! + 10)
r := n('1')
test.eq(11, r[0]!)
test.eq(13, r[1]!)
test.eq(-1, n('w')[0] !else -1)
o := fn(x str) => map([]str{x}, |y| int.parse(y)!)[0]! + base.*
test.eq(11, o('1')!)
test.eq(-1, o('w') !else -1)

-- In a function, and in a function with a template parameter.
fn run(x %T) -> !int:
    add := fn(y str) => int.parse(y)! + 1
    return add(str(x))! + 1
test.eq(7, run(5)!)
test.eq(error.InvalidCharacter, run('z').unwrap_error())

--cytest: pass