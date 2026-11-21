a := 123
b := move a
a

--cytest: error
--CompileError: `a` was moved at 2:11. Borrow it with `&a` or clone it to use it here.
--
--@MainPath():3:1:
--a
--^
--