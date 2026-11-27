const names []str = {'a', 'b', 'c'}

--cytest: error
--CompileError: A slice cannot be a constant: its copies share one buffer. Use a fixed array `[3]str`, or `global` for a value that changes.
--
--@MainPath():1:13:
--const names []str = {'a', 'b', 'c'}
--            ^~~~~
--
