out := []int{1, 2}
out.clear()

--cytest: error
--CompileError: The result of `clear` is the new list, and `out` keeps the old one. Write `out = out.clear()`.
--
--@MainPath():2:1:
--out.clear()
--^~~~~~~~~~~
--
