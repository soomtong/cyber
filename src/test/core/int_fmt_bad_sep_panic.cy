_ = 5.fmt(.dec, {sep=200})

--cytest: panic
--panic: Invalid sep: 200, expected an ASCII rune
--
--[trace]
--core:739:12 Int.fmt:
--    return int_fmt_config(self, format, config)
--           ^
--@MainPath():1:5 main:
--_ = 5.fmt(.dec, {sep=200})
--    ^
