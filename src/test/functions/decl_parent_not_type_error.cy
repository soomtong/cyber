fn foo() -> int:
    return 1

fn foo :: bar() -> int:
    return 2

--cytest: error
--CompileError: Can not declare `bar` for `foo`: `foo` is not a type. A method `fn (&T) name()` or a member `fn T :: name()` is declared for a type of this module.
--
--@MainPath():4:4:
--fn foo :: bar() -> int:
--   ^~~
--