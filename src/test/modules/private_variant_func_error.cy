use p 'test_mods/priv.cy'
b := p.Box[int]{v=1}
_ = b.peek()

--cytest: error
--CompileError: Can not access the private symbol `peek` in `Box[int]`. A symbol declared with `-` is only visible to the module that declares it.
--
--@MainPath():3:7:
--_ = b.peek()
--      ^~~~
--
