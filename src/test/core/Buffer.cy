use t 'test'

-- A buffer with a capacity and no elements.
b := Buffer[str](4)
t.eq(b.len(), 0)
t.eq(b.cap(), 4)
b << ('a' + 'b')
b << ('c' + 'd')
t.eq(b.len(), 2)
t.eq(b[1], 'cd')

-- size_down destructs the removed elements. It did not compile for a managed element.
b.size_down(1)
t.eq(b.len(), 1)
t.eq(b[0], 'ab')

-- A buffer of `n` copies of a value.
c := Buffer[int](3, 7)
t.eq(c.len(), 3)
t.eq(c[2], 7)
t.eq(c[1..].len(), 2)
t.eq(c[3..].len(), 0)
t.eq(c[1..3].len(), 2)

--cytest: pass
