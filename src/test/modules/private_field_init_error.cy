use p 'test_mods/priv.cy'
_ = p.Info{a=1, b=2}

--cytest: error
--CompileError: Can not access the private field `b` in `Info`. A symbol declared with `-` is only visible to the module that declares it.
--
--@MainPath():2:17:
--_ = p.Info{a=1, b=2}
--                ^
--
