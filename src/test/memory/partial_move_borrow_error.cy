type Inner:
    s str
    t str

type Outer:
    inner Inner
    x str

fn peek(inner &Inner):
    pass

o := Outer{inner=Inner{s='s', t='t'}, x='x'}
s := move o.inner.s
peek(&o.inner)

--cytest: error
--CompileError: Cannot borrow a partially moved value.
--
--@MainPath():14:6:
--peek(&o.inner)
--     ^~~~~~~~
--
