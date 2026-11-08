use p 'test_mods/priv.cy'
use test

-- Public members of a module that also declares private ones.
i := p.Info{a=3}
test.eq(i.sum(), 3)

-- A public function may use the private symbols of its own module.
test.eq(p.reveal(), 22)

-- Template instance: public field and method, private ones are used inside the module.
b := p.Box[int]{v=5}
test.eq(b.tag_of(), 0)
test.eq(b.v, 5)

--cytest: pass
