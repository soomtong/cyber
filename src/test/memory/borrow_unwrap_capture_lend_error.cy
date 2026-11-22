-- An unwrap capture that is stored keeps the owner of the option borrowed.
fn pick(scope p &int) -> scope ?&int:
    return p

a := Array[int]{1, 2, 3}
x := 7
var r &int = &x
if pick(&a[0]) |q|:
    r = q
a << 4
print(r.*)

--cytest: error
--CompileError: Expected exclusive access. There is another active borrow to `a`.
--
--@MainPath():10:1:
--a << 4
--^
--