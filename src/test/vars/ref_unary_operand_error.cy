n := 3
r := &n
print(-r)

--cytest: error
--CompileError: Can not use `-` on `&int`. Dereference it first: `-r.*`.
--
--@MainPath():3:7:
--print(-r)
--      ^~
--
