out := []int{1, 2}
out.appended(3)

--cytest: error
--CompileError: `appended` returns a new list and leaves `out` as it was. To change `out` in place, write `out.append(3)`.
--
--@MainPath():2:1:
--out.appended(3)
--^~~~~~~~~~~~~~~
--