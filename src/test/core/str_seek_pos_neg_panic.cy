s := 'héllo'
_ = s.seek_pos(-1)

--cytest: panic
--panic: Out of bounds rune index: -1
--
--[trace]
--@MainPath():2:5 main:
--_ = s.seek_pos(-1)
--    ^
--