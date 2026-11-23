use test

-- A `!` that leaves an inferred lambda makes the result type of the lambda `!U`, where `U` is the type of the
-- body. The template parameter in the return type is bound to it.
fn map(items []%T, f fn(T) -> %U) -> []U:
    out := []U{}
    for items |it|:
        out += f(it)
    return out

res := map([]str{'1', 'b'}, |x| int.parse(x)! * 2)
test.eq(2, res[0]!)
test.eq(error.InvalidCharacter, res[1].unwrap_error())

strs := map([]str{'1', 'b'}, |x| 'v' + str(int.parse(x)!))
test.eq('v1', strs[0]!)
test.eq('none', strs[1] !else 'none')

-- A closure, for a `Func` parameter.
fn each(items []%T, f Func[fn(T) -> %U]) -> []U:
    out := []U{}
    for items |it|:
        out += f(it)
    return out
k := ^3
sums := each([]str{'1', 'q'}, |x| int.parse(x)! + k.*)
test.eq(4, sums[0]!)
test.eq(-1, sums[1] !else -1)

-- The function passes its own function parameter on.
fn twice(x %T, f fn(T) -> %U) -> []U:
    return map([]T{x, x}, f)
t := twice('7', |x| int.parse(x)!)
test.eq(7, t[1]!)
test.eq(-1, twice('q', |x| int.parse(x)!)[1] !else -1)

--cytest: pass