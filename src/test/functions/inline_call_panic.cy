fn inner(x int) -> int:
    return 10 / x

fn outer(x int) -> int:
    return inner(x) + 1

-- `outer` is inlined into main. Its frame still shows in the trace between `inner` and main.
print(outer(0))

--cytest: panic
--panic: Division by zero.
--
--[trace]
--@MainPath():2:12 inner:
--    return 10 / x
--           ^
--@MainPath():5:12 outer:
--    return inner(x) + 1
--           ^
--@MainPath():8:7 main:
--print(outer(0))
--      ^
