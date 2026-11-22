print(Int[24].min)

--cytest: error
--CompileError: Unsupported bit size `24` for `Int`. Expected 8, 16, 32 or 64.
--
--@MainPath():1:7:
--print(Int[24].min)
--      ^~~~~~~
--