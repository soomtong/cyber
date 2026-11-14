res := ?int(none)
val := res ?else:
    pass

--cytest: error
--CompileError: An `?else` block must not reach its end. End it with `panic(...)`. To go on at the top level, give a default value (`x ?else default`) or unwrap it with `if x |v|:`.
--
--@MainPath():2:8:
--val := res ?else:
--       ^~~~~~~~~~
--