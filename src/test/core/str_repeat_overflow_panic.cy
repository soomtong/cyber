s := 'ab'
_ = s.repeat(1 << 62)

--cytest: panic
--panic: InvalidArgument
--
--[trace]
--@MainPath():2:5 main:
--_ = s.repeat(1 << 62)
--    ^
--