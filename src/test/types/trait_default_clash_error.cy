type Left trait:
    fn side() -> str:
        return 'left'

type Right trait:
    fn side() -> str:
        return 'right'

type Both:
    with Left
    with Right

--cytest: error
--CompileError: `Both` gets the default method `side` from both `Left` and `Right`. Declare `side` for `Both` to say what it does.
--
--@MainPath():11:10:
--    with Right
--         ^~~~~
--@MainPath():9:1:
--type Both:
--^~~~~~~~~
--
