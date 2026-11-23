use test

-- A `!` in an expression lambda with a declared return type returns the error as that type.
f := fn(x str) -> !int => int.parse(x)! + 1
test.eq(3, f('2')!)
test.eq(-1, f('a') !else -1)

-- An inferred return type works where nothing leaves the lambda early.
g := fn(x str) => int.parse(x) !else 0
test.eq(2, g('2'))
test.eq(0, g('a'))

-- The declared lambda binds the template parameter of the return type (`U` is `!int`).
fn map(items []%T, f fn(T) -> %U) -> []U:
    out := []U{}
    for items |it|:
        out += f(it)
    return out

res := map([]str{'4', 'b'}, fn(x str) -> !int => int.parse(x)! * 2)
test.eq(8, res[0]!)
test.eq(-1, res[1] !else -1)

--cytest: pass