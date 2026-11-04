use t 'test'

-- Iteration over a ref to the store.
a := ^ArrayStore[int]{}
a << 1
a << 2
a << 3
sum := 0
for a |it|:
    sum += it
t.eq(6, sum)

-- Pair iteration.
sum = 0
idxSum := 0
for a |idx, it|:
    sum += it
    idxSum += idx
t.eq(6, sum)
t.eq(3, idxSum)

-- Iteration over the dereferenced store.
sum = 0
for a.* |it|:
    sum += it
t.eq(6, sum)

-- The store is still valid after the loop.
t.eq(3, a.len())
t.eq(3, a[2])

-- Empty store.
b := ^ArrayStore[int]{}
sum = 0
for b |it|:
    sum += it
t.eq(0, sum)

-- Managed elements are copied out of the store.
names := ^ArrayStore[str]{}
names << 'a'
names << 'bc'
joined := ''
for names |n|:
    joined += n
t.eq('abc', joined)
t.eq('bc', names[1])

--cytest: pass
