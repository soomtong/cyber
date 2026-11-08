use p 'test_mods/priv.cy'
_ = p.LIMIT

--cytest: error
--CompileError: Can not access the private symbol `LIMIT` in `priv`. A symbol declared with `-` is only visible to the module that declares it.
--
--@MainPath():2:7:
--_ = p.LIMIT
--      ^~~~~
--
