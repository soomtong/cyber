x := 1e30
_ = int(x)

--cytest: panic
--panic: The float is NaN or out of the range of `int`.
--
--[trace]
--core:543:17 Int.@init:
--        i_64 := @floatToInt(float, x)
--                ^
--@MainPath():2:5 main:
--_ = int(x)
--    ^
