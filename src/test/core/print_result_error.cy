fn read() -> !str:
    return 'x'
print(read())

--cytest: error
--CompileError: Can not print `!str`. Unwrap it with `!` first, or handle the error with `!else` or `try`.
--
--@MainPath():3:1:
--print(read())
--^~~~~~~~~~~~~
--