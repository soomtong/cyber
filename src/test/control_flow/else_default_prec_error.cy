fn h() -> ?str:
    return none
if h() ?else '' == 'server':
    print(1)

--cytest: error
--CompileError: Expected type `str`, got `bool`. `?else` binds weaker than `==`, so this is the default value. Put the unwrap in parentheses: `(x ?else default) == y`.
--
--@MainPath():3:14:
--if h() ?else '' == 'server':
--             ^~~~~~~~~~~~~~
--