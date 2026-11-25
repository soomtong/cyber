use vec './test_mods/vec.cy'
use t 'test'

-- The operator function is found in the module that declares `Vec2`, not in this one.
a := vec.Vec2{x=1, y=2}
t.eq((a * 3.0).y, 6.0)
t.eq((3.0 * a).y, 6.0)
t.eq((2 * a).x, 2.0)

--cytest: pass