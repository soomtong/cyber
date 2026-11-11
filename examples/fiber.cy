-- The legacy fiber API (coinit/coresume/coyield) is deprecated.
-- Generators are the stackless replacement: `generator fn` turns the function into
-- a `Generator[Fn]` that runs until the next `yield` on each `next()` call.
generator fn go() -> int:
    print('start')
    yield 0
    for 0..100 |i|:
        print(i)
        yield i

gen := go()
while gen.status() != .done:
    _ = gen.next()
