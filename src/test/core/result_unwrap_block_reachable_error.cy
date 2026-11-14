res := Result[int](error.Invalid)
val := res !else |err|:
    pass

--cytest: error
--CompileError: An `!else` block must not reach its end. End it with `panic(...)`. To go on after the error at the top level, give a default value (`f() !else default`) or handle the error in a `try:` block with an `else:` block.
--
--@MainPath():2:8:
--val := res !else |err|:
--       ^~~~~~~~~~~~~~~~
--