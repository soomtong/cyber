out := 'a'
if out == none:
    print(1)

--cytest: error
--CompileError: `out` is `str`, which is never `none`. Compare with a value of the same type, for example `out.len() == 0`.
--
--@MainPath():2:11:
--if out == none:
--          ^~~~
--