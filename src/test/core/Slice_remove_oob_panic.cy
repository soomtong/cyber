a := []int{1, 2, 3}
_ = a.remove(3)

--cytest: panic
--panic: Out of bounds index: 3
--
--[trace]
--@MainPath():2:5 main:
--_ = a.remove(3)
--    ^
--