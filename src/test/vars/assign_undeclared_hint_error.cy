lines := {'a'}
report = lines.join(',')

--cytest: error
--CompileError: Undeclared variable `report`. To declare a new variable, write `report := ...`.
--
--@MainPath():2:1:
--report = lines.join(',')
--^~~~~~
--