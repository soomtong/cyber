fn r() -> !str:
    return 'a'
print(r().len())

--cytest: error
--CompileError: Can not find the symbol `len` in `!str`. Unwrap it with `!` first, or handle the error with `!else` or `try`.
--
--@MainPath():3:11:
--print(r().len())
--          ^~~
--