use td 'test_mods/trait_default.cy'

-- A trait of this file and a trait of a module give a default overload with the same parameters.
type Label trait:
    fn tag(n int) -> str:
        return 'label'

type Both:
    with td.Tag
    with Label

--cytest: error
--CompileError: `Both` gets the default method `tag` from both `Tag` and `Label`. Declare `tag` for `Both` to say what it does.
--
--@MainPath():10:10:
--    with Label
--         ^~~~~
--@MainPath():8:1:
--type Both:
--^~~~~~~~~
--
