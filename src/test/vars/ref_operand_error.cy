x := 1.5
r := &x
if r < 2.0:
    print(1)

--cytest: error
--CompileError: Can not use `<` on `&float`. Dereference it first: `r.* < ...`.
--
--@MainPath():3:4:
--if r < 2.0:
--   ^~~~~~~
--