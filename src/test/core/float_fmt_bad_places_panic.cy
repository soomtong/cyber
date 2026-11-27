_ = 1.5.fmt({places=-1})

--cytest: panic
--panic: Invalid places: -1, expected 0 to 100
--
--[trace]
--core:856:16 Float.fmt:
--        return f64_fmt_config(self, config)
--               ^
--@MainPath():1:5 main:
--_ = 1.5.fmt({places=-1})
--    ^
