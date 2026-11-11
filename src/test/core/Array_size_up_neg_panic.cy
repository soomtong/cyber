a := Array[int]{1, 2, 3}
a.size_up(-1, 0)

--cytest: panic
--panic: Invalid argument.
--
--[trace]
--@MainPath():2:1 main:
--a.size_up(-1, 0)
--^
--