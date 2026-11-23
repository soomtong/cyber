-- `%T` in the body of a function that declares `T` in its signature.
fn first(x []%T) -> T:
    var y %T = x[0]
    return y

print(first([]int{1, 2}))

--cytest: error
--CompileError: `%T` can only be declared in the signature of a function.
--
--@MainPath():3:11:
--    var y %T = x[0]
--          ^~
--While specializing `first[int]` here:
--@MainPath():6:7:
--print(first([]int{1, 2}))
--      ^~~~~~~~~~~~~~~~~~
--