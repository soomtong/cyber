var x Float[16] = 1

--cytest: error
--CompileError: Unsupported bit size `16` for `Float`. Expected 32 or 64.
--
--@MainPath():1:7:
--var x Float[16] = 1
--      ^~~~~~~~~
--