n := 1 << 62
a := Array[int](n, 0)

--cytest: panic
--panic: Invalid allocation length: 4611686018427387904
--
--[trace]
--@MainPath():2:6 main:
--a := Array[int](n, 0)
--     ^
--