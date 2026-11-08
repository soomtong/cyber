use * 'test_mods/priv.cy'
_ = secret()

--cytest: error
--CompileError: Undeclared variable `secret`.
--
--@MainPath():2:5:
--_ = secret()
--    ^~~~~~
--
