n := int.max
print(n + 1)

--cytest: panic
--panic: Integer overflow.
--
--[trace]
--@MainPath():2:7 main:
--print(n + 1)
--      ^
--