rows := ^[]str{}
rows.insert(0, 'a')

--cytest: error
--CompileError: Expected argument `&>[]str`, found `^[]str`, when calling `fn insert(&>[]str, int, str) -> void`. To change the value that `rows` points to, write `rows.*.insert(...)`.
--
--@MainPath():2:1:
--rows.insert(0, 'a')
--^~~~
--
