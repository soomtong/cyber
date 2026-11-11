generator fn watch(p ?&int) -> int:
    yield p.?.*

--cytest: error
--CompileError: A `generator fn` can not take the borrow type `?&int` as a parameter. The generator outlives the call, so pass an owned value or a `^T` pointer instead.
--
--@MainPath():1:20:
--generator fn watch(p ?&int) -> int:
--                   ^~~~~~~
--
