use t 'test'

-- `append`, `remove` and `clear` are also names of methods of other types. A call of one that returns nothing can
-- be the right side of a declaration, like any other call that returns nothing. Only a `Slice` method is an error
-- there (`Slice_append_decl_error.cy`).
type Buf:
    n int

fn (&Buf) clear():
    self.n = 0

var arr Array[int] = {}
_ = arr.append(2)
t.eq(1, arr.len())

var m Map[str, int] = {}
m['a'] = 1
_ = m.remove('a')
t.eq(0, m.size())

var b Buf = Buf{n=1}
_ = b.clear()
x := b.clear()
_ = x
t.eq(0, b.n)

--cytest: pass
