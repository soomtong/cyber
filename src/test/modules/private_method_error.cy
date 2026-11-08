use p 'test_mods/priv.cy'
i := p.Info{a=1}
_ = i.hidden_sum()

--cytest: error
--CompileError: Can not access the private symbol `hidden_sum` in `Info`. A symbol declared with `-` is only visible to the module that declares it.
--
--@MainPath():3:7:
--_ = i.hidden_sum()
--      ^~~~~~~~~~
--
