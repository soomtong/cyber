use t 'test'

1!

--cytest: error
--CompileError: Expected type instance of `Result`, found `int`. `!`, `!else` and `try` handle a `!T`. `int` has no error case, so use the value as it is.
--
--@MainPath():3:1:
--1!
--^
--