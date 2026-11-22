_ = r64(1).fmt(.dec, {width=-1})

--cytest: panic
--panic: Invalid width: -1
--
--[trace]
--@MainPath():1:5 main:
--_ = r64(1).fmt(.dec, {width=-1})
--    ^
--