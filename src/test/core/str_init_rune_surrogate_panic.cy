_ = str.init_rune(0xD800)

--cytest: panic
--panic: Invalid rune: 55296
--
--[trace]
--@MainPath():1:5 main:
--_ = str.init_rune(0xD800)
--    ^
--