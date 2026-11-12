use test

-- The index of the first future in the list that is done.
a := FutureResolver.new(int)
b := FutureResolver.new(int)
b.complete(7)
futs := []Future[int]{a.future(), b.future()}
i := Future.wait_any(futs.span())
test.eq(i, 1)
test.eq(futs[i].await(), 7)

-- When several are done, the first in the list.
a.complete(3)
test.eq(Future.wait_any(futs.span()), 0)
test.eq(futs[0].await(), 3)

-- A list of one.
test.eq(Future.wait_any([]Future[int]{Future.complete(5)}.span()), 0)

--cytest: pass