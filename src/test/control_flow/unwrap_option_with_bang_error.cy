s := 'a=b'
eq := s.index('=')!

--cytest: error
--CompileError: Expected type instance of `Result`, found `?int`. `!`, `!else` and `try` handle a `!T`. For `?int`, use `.?` or `?else`.
--
--@MainPath():2:7:
--eq := s.index('=')!
--      ^~~~~~~~~~~~
--