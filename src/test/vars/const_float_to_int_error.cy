const big = int(1e30)

--cytest: error
--CompileError: The float is NaN or out of the range of `int`.
--
--@MainPath():1:13:
--const big = int(1e30)
--            ^~~~~~~~~
--
