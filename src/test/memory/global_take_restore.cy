use t 'test'

-- A global can not be borrowed exclusively. A method call that changes a global `Slice` or `Array` in place takes
-- the value out of the global for the call and puts it back after it (take-and-restore). Heap strings make a lost
-- or doubled value show up as a leak or a double free.
global g []str = {}
global a Array[str] = {}

type State:
    items []str
    n     int
global st State = State{items={}, n=0}

fn add(s str):
    g.append(s)
    g += s.concat('!')

add('x'.concat(''))
g.append('y'.concat(''))
g.insert(0, 'z'.concat(''))
t.eq(4, g.len())
t.eq('z', g[0])
t.eq('x!', g[2])

-- A method that returns a value: the global holds its value again when the result is used.
v := g.pop().?
t.eq('y', v)
t.eq(3, g.len())

-- The condition of a loop takes and restores the global on every iteration.
var popped []str = {}
while g.pop() |w|:
    popped.append('%{w}:%{g.len()}')
t.eq(3, popped.len())
t.eq('x!:2', popped[0])
t.eq('z:0', popped[2])
t.eq(0, g.len())

-- `Array` and its `<<`.
a.append('a'.concat('1'))
a << 'a'.concat('2')
t.eq(2, a.len())

-- A field of a global.
st.items.append('i'.concat('1'))
st.items += 'i'.concat('2')
st.n += 1
t.eq(2, st.items.len())
t.eq('i2', st.items.pop().?)
t.eq(1, st.items.len())

-- A take inside the argument of another take: each one is put back after its own call.
global h []str = {}
h.append('h'.concat('1'))
g.append(h.pop().?)
t.eq('h1', g[0])
t.eq(0, h.len())

-- Through a pointer.
fn push(p Ptr[[]str], s str):
    p.*.append(s)
local := []str{}
push(*local, 'p'.concat('q'))
t.eq('pq', local[0])

-- Growing a global in a loop stays in place (no copy per element).
global nums []int = {}
fn fill(n int):
    for 0..n |i|:
        nums += i
fill(1000)
t.eq(1000, nums.len())
t.eq(999, nums[999])

--cytest: pass
