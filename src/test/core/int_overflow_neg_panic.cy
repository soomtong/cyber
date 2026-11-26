n := int.min
print(-n)

--cytest: panic
--panic: Integer overflow.
--
--[trace]
--@MainPath():2:7 main:
--print(-n)
--      ^
--