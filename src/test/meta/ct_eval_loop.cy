use test
use meta

-- A compile-time body whose loop runs zero times falls through to the next statement.
type Ints[const N int] const:
    fields := [N]meta.StructField({name='', type=void, offset=0, state_offset=0})
    for 0..N |i|:
        fields[i] = {name='p' + EvalStr(i), type=int, offset=0, state_offset=0}
    return meta.new_struct(fields, {tuple=true})

var a Ints[0] = {}
test.eq(0, type.size(Ints[0]))
var a2 Ints[2] = {1, 2}
test.eq(3, a2.p0 + a2.p1)

-- A `return` inside the loop ends the body, so later iterations do not replace it.
type One[const N int] const:
    for 0..N |i|:
        if i == 1:
            fields := [1]meta.StructField({name='p0', type=int, offset=0, state_offset=0})
            return meta.new_struct(fields, {tuple=true})
    fields := [1]meta.StructField({name='p0', type=str, offset=0, state_offset=0})
    return meta.new_struct(fields, {tuple=true})

var b One[3] = {10}
test.eq(10, b.p0)
var c One[0] = {'abc'}
test.eq('abc', c.p0)

--cytest: pass
