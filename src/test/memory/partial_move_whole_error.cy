type Foo:
    a int
    b str

f := Foo{a=123, b='abc'}
b := move f.b
g := move f

--cytest: error
--CompileError: Cannot move a partially moved value.
--
--@MainPath():7:11:
--g := move f
--          ^
--
