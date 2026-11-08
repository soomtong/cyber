a := 123
ref := &a
if true:
    b := 234
    ref = &b
print(ref.*)

--cytest: error
--CompileError: `ref` can not outlive `b`.
--
--@MainPath():5:11:
--    ref = &b
--          ^~
--
