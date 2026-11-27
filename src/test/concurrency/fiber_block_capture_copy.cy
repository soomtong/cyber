use t 'test'

-- A `fiber:` body is a closure: it keeps a copy of `n` from when the fiber is made, before its body runs.
n := 1
f := fiber:
    t.eq(n, 1)
    suspend
    t.eq(n, 1)
n = 2
t.eq(f.resume(), .suspended)
t.eq(f.resume(), .done)
t.eq(n, 2)

--cytest: pass
