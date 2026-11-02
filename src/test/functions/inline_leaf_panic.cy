fn div(a int, b int) -> int:
    return a / b

-- Integer division can panic, so `div` is not inlined and keeps its frame in the trace.
print(div(1, 0))

--cytest: panic
--panic: Division by zero.
--
--[trace]
--@MainPath():2:12 div:
--    return a / b
--           ^
--@MainPath():5:7 main:
--print(div(1, 0))
--      ^
