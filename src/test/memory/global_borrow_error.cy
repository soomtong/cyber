type F = fn() -> int

global gf ?OpaqueFunc[F] = none
print(1)

--cytest: error
--CompileError: A global cannot hold the borrow type `?OpaqueFunc[fn() -> int]`. Use an owned type such as `^T`.
--
--@MainPath():3:11:
--global gf ?OpaqueFunc[F] = none
--          ^~~~~~~~~~~~~~
--