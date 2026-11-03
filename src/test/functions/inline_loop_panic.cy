fn inner(x int) -> int:
    return 10 / x

fn outer(n int) -> int:
    total := 0
    for 0..n |i|:
        total += inner(2 - i)
    return total

-- `outer` and its loop are inlined into main. A panic in a later iteration still shows each frame.
print(outer(4))

--cytest: panic
--panic: Division by zero.
--
--[trace]
--@MainPath():2:12 inner:
--    return 10 / x
--           ^
--@MainPath():7:18 outer:
--        total += inner(2 - i)
--                 ^
--@MainPath():11:7 main:
--print(outer(4))
--      ^
