use p 'test_mods/priv_choice.cy'
use t 'test'

-- A private choice type is copied and destructed through core templates that name `T.Tag`.
-- `Tag` belongs to the choice, so it is not private on its own.
t.eq(3, p.count_names())

-type Local enum:
    case a int
    case b str

var xs []Local = {Local.a(1), Local.b('x')}
ys := xs
t.eq(2, ys.len())

--cytest: pass
