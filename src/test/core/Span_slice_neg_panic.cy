a := Array[int]{1, 2, 3}
s := a[..]
_ = s[-1..]

--cytest: panic
--panic: Out of bounds index: -1
--
--[trace]
--@MainPath():3:5 main:
--_ = s[-1..]
--    ^
--