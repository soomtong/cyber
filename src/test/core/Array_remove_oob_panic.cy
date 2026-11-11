a := Array[int]{1, 2, 3}
a.remove(3)

--cytest: panic
--panic: Out of bounds index: 3
--
--[trace]
--@MainPath():2:1 main:
--a.remove(3)
--^
--