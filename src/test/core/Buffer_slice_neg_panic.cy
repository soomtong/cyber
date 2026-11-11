b := Buffer[int](2, 7)
_ = b[-1..]

--cytest: panic
--panic: Out of bounds index: -1
--
--[trace]
--@MainPath():2:5 main:
--_ = b[-1..]
--    ^
--