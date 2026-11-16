use test

-- The pads of a cancelled fiber run from the top frame down. A `@deinit` that a pad calls can grow the fiber's stack
-- and move it. The frames that wait for their own pad are patched then, so a `@deinit` that runs later still reads
-- its borrow (F-158). Before, it read the stack that was freed.
global seen int = 0

fn rec(n int) -> int:
    if n == 0: return 0
    return rec(n - 1) + 1

-- Grows the stack in its `@deinit`.
type Deep:
    id int
fn (&Deep) @deinit():
    _ = rec(3000)

type View:
    r &int
fn (&View) @deinit():
    seen += self.r.*

type RawView:
    r Ptr[int]
    pad int
fn (&RawView) @deinit():
    seen += self.r.*

-- The borrow is in a frame under the one that grows the stack.
fn upper():
    d := Deep{id=1}
    suspend

fn below():
    x := 40
    v := View{r=&x}
    w := RawView{r=*x, pad=0}
    upper()

fn cancel_below():
    f := fiber below()
    _ = f.resume()
    test.eq(f.cancel(), true)
seen = 0
cancel_below()
test.eq(seen, 80)

-- The borrow is in the frame whose pad grows the stack, in a block whose registers a later local uses again.
fn same(stop bool):
    x := 40
    if stop:
        v := View{r=&x}
        w := RawView{r=*x, pad=0}
        d := Deep{id=1}
        suspend
    y := 5
    z := 6
    k := 7
    seen += y + z + k

fn cancel_same():
    f := fiber same(true)
    _ = f.resume()
    test.eq(f.cancel(), true)
seen = 0
cancel_same()
test.eq(seen, 80)

-- The fiber is dropped instead of cancelled.
fn drop_below():
    f := fiber below()
    _ = f.resume()
seen = 0
drop_below()
test.eq(seen, 80)

--cytest: pass
