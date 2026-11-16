use t 'test'

-- The resize ops return the new list and leave the receiver as it was, even when the receiver
-- held the only reference to the buffer. Before, `remove` and `size_down` destructed elements the
-- receiver still saw, and `insert` shifted them.
out := []str{'a'.concat(''), 'b'.concat(''), 'c'.concat('')}

r := out.remove(1)
t.eq(3, out.len())
t.eq('b', out[1])
t.eq(2, r.len())
t.eq('c', r[1])

last := out.remove(2)
t.eq('c', out[2])
t.eq(2, last.len())

c := out.clear()
t.eq(3, out.len())
t.eq('a', out[0])
t.eq('c', out[2])
t.eq(0, c.len())

i := out.insert(0, 'z'.concat(''))
t.eq('a', out[0])
t.eq('b', out[1])
t.eq(3, out.len())
t.eq('z', i[0])
t.eq('a', i[1])
t.eq(4, i.len())

-- The shorter view grows over the elements the receiver still sees.
d := out.size_down(1)
d = d.append('q'.concat(''))
t.eq('b', out[1])
t.eq('q', d[1])
t.eq(2, d.len())

-- The two removals twice in a row (the panic in the request).
twice := []str{'a'.concat(''), 'b'.concat('')}
t1 := twice.remove(1)
t2 := twice.remove(1)
t.eq('b', twice[1])
t.eq(1, t1.len())
t.eq(1, t2.len())

-- Assigning back still works in place.
out = out.remove(0)
out = out.remove(out.len() - 1)
t.eq(1, out.len())
t.eq('b', out[0])
out = out.clear()
out = out.append('n'.concat(''))
t.eq(1, out.len())
t.eq('n', out[0])

-- The model's loop from the request, written with the result assigned back.
lines := []str{'x'.concat(''), ''.concat(''), ' '.concat('')}
while lines.len() > 0 and lines.last().trim() == '':
    lines = lines.remove(lines.len() - 1)
t.eq(1, lines.len())

ints := []int{1, 2}
m := ints.remove(1)
t.eq(2, ints.len())
t.eq(2, ints[1])
t.eq(1, m.len())

--cytest: pass
