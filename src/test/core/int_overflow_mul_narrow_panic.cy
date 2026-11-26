n := i32(65536)
print(n * n)

--cytest: panic
--panic: Integer overflow.
--
--[trace]
--@MainPath():2:7 main:
--print(n * n)
--      ^
--