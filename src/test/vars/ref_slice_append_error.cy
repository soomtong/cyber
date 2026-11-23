rows := ^[]str{}
rows.append('a')

--cytest: error
--CompileError: Expected argument `&>[]str`, found `^[]str`, when calling `fn append(&>[]str, str) -> void`. To change the value that `rows` points to, write `rows.*.append(...)`.
--
--@MainPath():2:1:
--rows.append('a')
--^~~~
--
