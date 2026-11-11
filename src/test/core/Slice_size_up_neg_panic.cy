a := []int{1, 2, 3}
_ = a.size_up(-1, 0)

--cytest: panic
--panic: Invalid argument.
--
--[trace]
--@MainPath():2:5 main:
--_ = a.size_up(-1, 0)
--    ^
--