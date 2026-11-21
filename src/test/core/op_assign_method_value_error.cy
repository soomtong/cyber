-- An `op=` method that returns a value: the hint must not be `_ = a += 2`, which is not a statement.
type Acc:
    n int

fn (&Acc) `+=`(o int) -> int:
    self.n += o
    return self.n

a := Acc{n=1}
a += 2
print(a.n)

--cytest: error
--CompileError: The `+=` method of `Acc` returns `int`, and an `x += y` statement can not use or drop the value. Declare the method without a return type.
--
--@MainPath():10:1:
--a += 2
--^~~~~~
--