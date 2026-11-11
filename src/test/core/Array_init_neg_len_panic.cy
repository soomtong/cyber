n := -1
a := Array[int](n, 0)

--cytest: panic
--panic: Invalid allocation length: -1
--
--[trace]
--@MainPath():2:6 main:
--a := Array[int](n, 0)
--     ^
--