use test
use meta
use c

-- `meta.enum_from_int` converts an integer to an enum case.
type Color enum:
    case red
    case blue
test.eq(meta.enum_from_int(Color, 1)!, Color.blue)
test.eq(meta.enum_from_int(Color, 0)!, Color.red)
test.eq(meta.enum_from_int(Color, 9) !else Color.red, Color.red)
test.eq(int(Color.blue), 1)

-- `c.memcpy` copies raw bytes.
a := alloc(byte, 4)
b := alloc(byte, 4)
for 0..4 |i|:
    a[i] = byte(i + 1)
    b[i] = 0
c.memcpy(b.ptr, a.ptr, 4)
test.eq(int(b[0]), 1)
test.eq(int(b[3]), 4)
free(as a.ptr)
free(as b.ptr)

-- `meta.consume` ends a local without its `@deinit`.
global deinits int = 0
type Res:
    v int
fn (&Res) @deinit():
    deinits += 1
fn (sink Res) take() -> int:
    v := self.v
    meta.consume(self)
    return v
test.eq(Res{v=5}.take(), 5)
test.eq(deinits, 0)

--cytest: pass
