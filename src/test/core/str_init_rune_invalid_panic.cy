_ = str.init_rune(0x200000)

--cytest: panic
--panic: Invalid rune: 2097152
--
--[trace]
--@MainPath():1:5 main:
--_ = str.init_rune(0x200000)
--    ^
--