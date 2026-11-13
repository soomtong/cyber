fn count() -> !int:
    return 1
s := 'n=%{count()}'

--cytest: error
--CompileError: Can not print `!int`. Unwrap it with `!` first, or handle the error with `!else` or `try`.
--
--@MainPath():3:11:
--s := 'n=%{count()}'
--          ^~~~~~~
--