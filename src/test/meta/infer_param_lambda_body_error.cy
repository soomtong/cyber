-- The body of the lambda is checked with the parameter types that are known.
fn map(items []%T, f fn(T) -> %U) -> []U:
    out := []U{}
    for items |it|:
        out += f(it)
    return out

print(map([]int{1, 2}, |x| x.foo))

--cytest: error
--CompileError: Field `foo` does not exist in `int`.
--
--@MainPath():8:30:
--print(map([]int{1, 2}, |x| x.foo))
--                             ^~~
--