type R struct:
    with NoCopy
    id int

x := R{id=1}
a := Array[R]{x}
print(x.id)

--cytest: error
--CompileError: `x` was moved at 6:15. Borrow it with `&x` or clone it to use it here.
--
--@MainPath():7:7:
--print(x.id)
--      ^
--