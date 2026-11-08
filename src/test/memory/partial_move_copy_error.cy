type Foo:
    a int
    b str

f := Foo{a=123, b='abc'}
b := move f.b
g := f

--cytest: error
--CompileError: Cannot copy a partially moved value.
--
--@MainPath():7:6:
--g := f
--     ^
--
