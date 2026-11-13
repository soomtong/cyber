s := {a=1}

--cytest: error
--CompileError: Expected a target type for a key value initializer, such as `Map[str, int]{a=1}`.
--
--@MainPath():1:6:
--s := {a=1}
--     ^~~~~
--