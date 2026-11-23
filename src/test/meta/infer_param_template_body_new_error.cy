-- `%Q` in the body of a function with template parameters. The signature does not declare `Q`.
fn first(x []%T) -> T:
    var y []%Q = x
    return y[0]

print(first([]int{1, 2}))

--cytest: error
--CompileError: `%Q` can only be declared in the signature of a function.
--
--@MainPath():3:13:
--    var y []%Q = x
--            ^~
--While specializing `first[int]` here:
--@MainPath():6:7:
--print(first([]int{1, 2}))
--      ^~~~~~~~~~~~~~~~~~
--