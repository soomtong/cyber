fn gen() -> int:
    yield 1
    return 2

g := gen()
print(g)

--cytest: error
--CompileError: `yield` is only allowed in a `generator fn`.
--
--@MainPath():2:5:
--    yield 1
--    ^~~~~~~
--
