-- An error in the body of a template instance names the instances that led to it.
fn inner(x %T) -> int:
    return x.size()

fn outer(x %T) -> int:
    return inner(x) + 1

print(outer(3))

--cytest: error
--CompileError: Can not find the symbol `size` in `int`.
--
--@MainPath():3:14:
--    return x.size()
--             ^~~~
--While specializing `inner[int]` here:
--@MainPath():6:12:
--    return inner(x) + 1
--           ^~~~~~~~
--While specializing `outer[int]` here:
--@MainPath():8:7:
--print(outer(3))
--      ^~~~~~~~
--