idx := 'a'.index('b')
if not idx:
    print(1)

--cytest: error
--CompileError: `not` takes a `bool`. Found `?int`. For an option, compare with `none` (`x == none`), unwrap it with `if x |v|:`, or give a default with `?else`.
--
--@MainPath():2:4:
--if not idx:
--   ^~~~~~~
--