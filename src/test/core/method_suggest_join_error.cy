out := []str{'a', 'b'}
s := '\n'.join(out)

--cytest: error
--CompileError: Can not find the symbol `join` in `str`. `join` is a method of a list: `xs.join(sep)`.
--
--@MainPath():2:11:
--s := '\n'.join(out)
--          ^~~~
--