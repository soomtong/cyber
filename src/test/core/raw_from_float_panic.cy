f := -1.0
_ = r64(f)

--cytest: panic
--panic: Lossy conversion to `r64`.
--
--[trace]
--@MainPath():2:5 main:
--_ = r64(f)
--    ^
--