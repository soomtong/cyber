fn div(a int, b int) -> int:
    return a / b

-- `div` is inlined into main. The trace still shows its frame.
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
