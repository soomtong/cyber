use test
use meta

-- A type const that returns an existing type leaves it as it is. It used to be renamed, so `int`
-- became `MyInt` and its methods were not found.
type MyInt const:
    return int

var v MyInt = 3
test.eq(4, v + 1)
test.eq('3', '%{v}')
test.eq('int', type.name(int))
test.eq('int', type.name(MyInt))

-- A type created by the body takes the const's name.
type Pair const:
    fields := [2]meta.StructField({name='', type=void, offset=0, state_offset=0})
    fields[0] = {name='a', type=int, offset=0, state_offset=0}
    fields[1] = {name='b', type=int, offset=0, state_offset=0}
    return meta.new_struct(fields, {tuple=false})

var p Pair = {a=1, b=2}
test.eq(3, p.a + p.b)
test.eq('Pair', type.name(Pair))

--cytest: pass
