fn inner(x int) -> int:
    return 10 / x

fn middle(x int) -> int:
    return inner(x) + 1

fn outer(x int) -> int:
    return middle(x) * 2

-- `outer`, `middle` and `inner` are inlined into main. The trace still shows each frame.
print(outer(0))

--cytest: panic
--panic: Division by zero.
--
--[trace]
--@MainPath():2:12 inner:
--    return 10 / x
--           ^
--@MainPath():5:12 middle:
--    return inner(x) + 1
--           ^
--@MainPath():8:12 outer:
--    return middle(x) * 2
--           ^
--@MainPath():11:7 main:
--print(outer(0))
--      ^
