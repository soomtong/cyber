f := true
r := &f
print(not r)

--cytest: error
--CompileError: Can not use `not` on `&bool`. Dereference it first: `not r.*`.
--
--@MainPath():3:7:
--print(not r)
--      ^~~~~
--
