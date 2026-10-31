use os

start := os.now()!

-- The old fiber API (coinit/coresume/coyield) is gone. Generators are the stackless
-- replacement: each one is resumed once when created and once more in the second loop.
global count int = 0

#[generator]
fn inc() -> int:
    count += 1
    yield 0
    count += 1

type IncFn = fn() -> int

gens := Array[^Generator[IncFn]]{}
for 0..100000:
    g := inc()
    _ = g.next()
    gens.append(g)

for gens |g|:
    _ = g.next()

print('time: %{float(os.now()! - start) / 1000000}')
print(count)
