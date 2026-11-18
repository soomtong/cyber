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

-- An argument is evaluated before the value is taken out, so it reads the global as it was: directly, through a
-- function, and through a method that takes the global itself.
global q []int = {1, 2, 3}
fn q_len() -> int:
    return q.len()
q.append(q.len())
q.append(q_len())
(q).append(q.len())
q.append(q.pop().?)
q += q
t.eq(12, q.len())
t.eq(3, q[3])
t.eq(4, q[4])
t.eq(5, q[5])
t.eq(1, q[6])
q.size_up(14, q_len())
t.eq(12, q[13])

-- An argument that leaves the call (`!` in a function, `!` in a `try`) leaves the global as it was.
fn fail() -> !str:
    return error.Bad
fn add_failing() -> !void:
    g += fail()!
fn try_add() -> bool:
    add_failing() !else |e|:
        return false
    return true
g_before := g.len()
t.eq(false, try_add())
t.eq(g_before, g.len())
t.eq('h1', g[0])
try:
    q.append(int.parse('zz')!)
else |e|:
    pass
t.eq(14, q.len())
t.eq(false, try_add_field())
t.eq(1, st.items.len())
fn add_field_failing() -> !void:
    st.items.append(fail()!)
fn try_add_field() -> bool:
    add_field_failing() !else |e|:
        return false
    return true

-- A method with more than one function of the name: a list, a span, and their `+=`.
local_more := []int{7, 8}
q.clear()
q.append(local_more)
q.append(local_more.span())
q += local_more
q += local_more.span()
t.eq(8, q.len())
global ga Array[int] = {}
ga.append(local_more)
t.eq(2, ga.len())

-- Another field of the same global can be an argument, also as a borrow.
type Pair:
    xs []int
    ys []int
    n  int
global pair Pair = Pair{xs={1}, ys={5, 6}, n=7}
pair.xs.append(pair.n)
pair.xs.append(pair.ys.span())
pair.xs += pair.ys
t.eq(6, pair.xs.len())
t.eq(7, pair.xs[1])
t.eq(6, pair.xs[5])

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
