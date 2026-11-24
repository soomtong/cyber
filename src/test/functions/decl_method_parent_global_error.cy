global g int = 1

fn (&g) bar() -> int:
    return 2

--cytest: error
--CompileError: Can not declare `bar` for `g`: `g` is not a type. A method `fn (&T) name()` or a member `fn T :: name()` is declared for a type of this module.
--
--@MainPath():3:6:
--fn (&g) bar() -> int:
--     ^
--