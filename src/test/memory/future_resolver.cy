use t 'test'

-- `@notifyFutureComplete` borrows the future value. When it took `Future[T]` by value,
-- the host function owned a copy that it never released, so the `FutureValue` leaked.
r := FutureResolver.new(int)
r.complete(234)
t.eq(234, r.future().await())

--cytest: pass
