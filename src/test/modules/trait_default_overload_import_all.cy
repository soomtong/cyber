use test
use * 'test_mods/trait_default.cy'
use * 'test_mods/trait_default_impl.cy'

-- The same with `use *`: the trait and the types are named without the module.
-- Both modules declare a method `show` (for `Local` and for `Far`). `use *` takes the names of a module,
-- not the methods of its types, so the two do not clash.
type A:
    with Show
    n int

fn (&A) show(indent int) -> str:
    return 'A%{self.n}@%{indent}'

a := A{n=1}
test.eq('A1@0', a.show())
test.eq('A1@5', a.show(2, 3))
test.eq('A1@0|A1@3', via(&a))

far := Far{n=2}
test.eq('far2@0', far.show())
test.eq('far2@3', far.show(1, 2))
var show ^Dyn[Show] = ^Far{n=3}
test.eq('far3@0', show.show())
show = ^Local{n=4}
test.eq('local4@7', show.show(3, 4))
test.eq('far-tag1', FarTag{}.tag())

--cytest: pass
