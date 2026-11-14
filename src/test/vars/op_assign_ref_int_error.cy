n := ^int(1)
n += 2

--cytest: error
--CompileError: Can not use `+` on `^int`. To change the value that `n` points to, write `n.* += ...`.
--
--@MainPath():2:1:
--n += 2
--^~~~~~
--