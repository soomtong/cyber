-- A `switch` capture that the result takes keeps the owner of the control borrowed.
type Ref enum:
    case none
    case one &int

fn pick(scope p &int) -> scope Ref:
    return Ref.one(p)

a := Array[int]{1, 2, 3}
x := 7
s := switch pick(&a[0]):
    case .one |p| => p
    else => &x
a << 4
print(s.*)

--cytest: error
--CompileError: Expected exclusive access. There is another active borrow to `a`.
--
--@MainPath():14:1:
--a << 4
--^
--