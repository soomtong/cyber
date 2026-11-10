m := Map[str, int]{a = 1}
for m |&e|:
    pass

--cytest: error
--CompileError: `Map[str, int]` can not be iterated by borrow. It has no `next_borrow` method.
--
--@MainPath():2:8:
--for m |&e|:
--       ^~
--
