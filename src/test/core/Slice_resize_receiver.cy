use t 'test'

-- The resize ops change the receiver in place (`append`, `insert`, `remove`, `clear`, `size_down`, `size_up`).
-- The ops that return a new list (`appended`, `inserted`, `removed`, `+`) leave the receiver as it was.
out := []str{'a'.concat(''), 'b'.concat(''), 'c'.concat('')}

r := out.removed(1)
t.eq(3, out.len())
t.eq('b', out[1])
t.eq(2, r.len())
t.eq('c', r[1])

last := out.removed(2)
t.eq('c', out[2])
t.eq(2, last.len())

i := out.inserted(0, 'z'.concat(''))
t.eq('a', out[0])
t.eq(3, out.len())
t.eq('z', i[0])
t.eq('a', i[1])
t.eq(4, i.len())

-- In place.
out.remove(0)
out.remove(out.len() - 1)
t.eq(1, out.len())
t.eq('b', out[0])
out.insert(0, 'y'.concat(''))
t.eq('y', out[0])
t.eq('b', out[1])
out.clear()
t.eq(0, out.len())
out.append('n'.concat(''))
t.eq(1, out.len())
t.eq('n', out[0])

-- The two removals twice in a row (the panic in the tars-agent 0.4.12 request).
twice := []str{'a'.concat(''), 'b'.concat('')}
twice.remove(1)
twice.remove(0)
t.eq(0, twice.len())

-- The model's loop from the request.
lines := []str{'x'.concat(''), ''.concat(''), ' '.concat('')}
while lines.len() > 0 and lines.last().trim() == '':
    lines.remove(lines.len() - 1)
t.eq(1, lines.len())

-- A field changes in place.
type Log:
    lines []str
log := Log{lines={}}
log.lines.append('l'.concat('1'))
log.lines += 'l'.concat('2')
log.lines.remove(0)
t.eq(1, log.lines.len())
t.eq('l2', log.lines[0])

ints := []int{1, 2}
m := ints.removed(1)
t.eq(2, ints.len())
t.eq(2, ints[1])
t.eq(1, m.len())
ints.remove(0)
t.eq(2, ints[0])

-- `+=` on a global appends in place: the call takes the value out of the global and puts it back.
global gl []str = {}
fn add_gl(s str):
    gl += s
add_gl('g'.concat('1'))
add_gl('g'.concat('2'))
t.eq(2, gl.len())
t.eq('g2', gl[1])

--cytest: pass
