use p 'test_mods/priv.cy'
i := p.Info{a=1}
r := &i
_ = r.b

--cytest: error
--CompileError: Can not access the private field `b` in `Info`. A symbol declared with `-` is only visible to the module that declares it.
--
--@MainPath():4:7:
--_ = r.b
--      ^
--
