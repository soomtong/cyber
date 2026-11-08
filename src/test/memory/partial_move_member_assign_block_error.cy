type Foo:
    a int
    b str

f := Foo{a=123, b='abc'}
b := move f.b
if true:
    f.b = 'xyz'

--cytest: error
--CompileError: Can only assign to a moved member of a variable declared in the same block.
--
--@MainPath():8:7:
--    f.b = 'xyz'
--      ^
--
