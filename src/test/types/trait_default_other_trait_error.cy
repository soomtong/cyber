type Left trait:
    fn side() -> str:
        return 'left'

type Right trait:
    fn side() -> str

type Both:
    with Left
    with Right

--cytest: error
--CompileError: `Both` has the method `side` only as a default method of `Left`. Declare `side` for `Both` to implement `Right`.
--
--@MainPath():10:10:
--    with Right
--         ^~~~~
--@MainPath():8:1:
--type Both:
--^~~~~~~~~
--
