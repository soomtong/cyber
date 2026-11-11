y := type.size('s')

--cytest: error
--CompileError: Expected argument `type`, found `EvalStr`, when calling `fn size(type) -> int`.
--
--@MainPath():1:16:
--y := type.size('s')
--               ^~~
--
