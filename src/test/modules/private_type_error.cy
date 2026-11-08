use p 'test_mods/priv.cy'
_ = p.Hidden{v=1}

--cytest: error
--CompileError: Can not access the private symbol `Hidden` in `priv`. A symbol declared with `-` is only visible to the module that declares it.
--
--@MainPath():2:7:
--_ = p.Hidden{v=1}
--      ^~~~~~
--
