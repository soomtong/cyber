-- Two traits give a default overload with the same parameters.
type Left trait:
    fn side() -> str:
        return 'left'

    fn side(n int) -> str:
        return 'left'

type Right trait:
    fn side(n int) -> str:
        return 'right'

type Both:
    with Left
    with Right

--cytest: error
--CompileError: `Both` gets the default method `side` from both `Left` and `Right`. Declare `side` for `Both` to say what it does.
--
--@MainPath():15:10:
--    with Right
--         ^~~~~
--@MainPath():13:1:
--type Both:
--^~~~~~~~~
--
