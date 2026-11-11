a := []int{1, 2, 3}
_ = a[-1..2]

--cytest: panic
--panic: Out of bounds index: -1
--
--[trace]
--@MainPath():2:5 main:
--_ = a[-1..2]
--    ^
--