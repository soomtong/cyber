use * 'test_mods/priv.cy'
use test

-- `use *` imports the public symbols only. The private ones still work inside the module.
test.eq(reveal(), 22)
i := Info{a=3}
test.eq(i.sum(), 3)

--cytest: pass
