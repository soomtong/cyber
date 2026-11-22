use meta

_ = meta.eval(1 + 2)

--cytest: error
--CompileError: `meta.eval` is not supported yet. Use the compile-time expression `#{}`.
--
--@MainPath():3:5:
--_ = meta.eval(1 + 2)
--    ^~~~~~~~~~~~~~~~
--