use p 'test_mods/priv.cy'
i := p.Info{a=1}
i.b = 3

--cytest: error
--CompileError: Can not access the private field `b` in `Info`. A symbol declared with `-` is only visible to the module that declares it.
--
--@MainPath():3:3:
--i.b = 3
--  ^
--
