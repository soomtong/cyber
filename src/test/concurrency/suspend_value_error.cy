fn work():
    suspend 1

--cytest: error
--ParseError: `suspend` takes no value. Use `yield` in a generator.
--
--@MainPath():2:13:
--    suspend 1
--            ^
--
