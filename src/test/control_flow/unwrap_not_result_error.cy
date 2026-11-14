fn b() -> str:
    return 'a'
print(b()!)

--cytest: error
--CompileError: Expected type instance of `Result`, found `str`. `!`, `!else` and `try` handle a `!T`. `str` has no error case, so use the value as it is.
--
--@MainPath():3:7:
--print(b()!)
--      ^~~
--