use lib 'test_mods/take_template.cy'
use t 'test'

xs := []int{}
lib.push_all[int](*xs, 1, 2)
t.eq(2, xs.len())
t.eq(2, lib.total())

--cytest: pass
