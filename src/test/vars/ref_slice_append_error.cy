rows := ^[]str{}
rows.append('a')

--cytest: error
--CompileError: Expected type `&>[]str`. Found `^[]str`. To change the value that `rows` points to, write `rows.*.append(...)`.
--
--@MainPath():2:1:
--rows.append('a')
--^~~~
--
