use p 'test_mods/priv.cy'
_ = p.secret()

--cytest: error
--CompileError: Can not access the private symbol `secret` in `priv`. A symbol declared with `-` is only visible to the module that declares it.
--
--@MainPath():2:7:
--_ = p.secret()
--      ^~~~~~
--
