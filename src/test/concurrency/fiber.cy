use test

-- A fiber does not start until the first resume. The arguments are evaluated when it is created.
fn append(list ^ArrayStore[int], v int):
    list << v
list := ^ArrayStore[int]{}
f1 := fiber append(list, 123)
test.eq(list.len(), 0)
test.eq(f1.status(), .suspended)
test.eq(f1.resume(), .done)
test.eq(list.len(), 1)
test.eq(list[0], 123)
test.eq(f1.status(), .done)

-- Resuming a fiber that is done returns `.done`.
test.eq(f1.resume(), .done)
test.eq(list.len(), 1)

-- `suspend` gives control back to `resume`, which returns `.suspended`.
fn steps(list ^ArrayStore[int]):
    list << 1
    suspend
    list << 2
    suspend
    list << 3
list = ^ArrayStore[int]{}
f2 := fiber steps(list)
test.eq(f2.resume(), .suspended)
test.eq(list.len(), 1)
test.eq(f2.resume(), .suspended)
test.eq(list.len(), 2)
test.eq(f2.resume(), .done)
test.eq(list.len(), 3)

-- Two fibers interleave on the same heap.
fn worker(name str, n int, log ^ArrayStore[str]):
    for 0..n |i|:
        log << '%{name}%{i}'
        suspend
log := ^ArrayStore[str]{}
fa := fiber worker('a', 2, log)
fb := fiber worker('b', 3, log)
while fa.status() != .done or fb.status() != .done:
    _ = fa.resume()
    _ = fb.resume()
test.eq(log.len(), 5)
test.eq(log[0], 'a0')
test.eq(log[1], 'b0')
test.eq(log[2], 'a1')
test.eq(log[3], 'b1')
test.eq(log[4], 'b2')

-- `suspend` works at any call depth. The frames and their locals stay on the fiber's stack.
fn deep(n int) -> int:
    if n == 0:
        suspend
        return 0
    keep := n
    res := deep(n - 1)
    return res + keep
fn deep_entry(list ^ArrayStore[int]):
    list << deep(10)
list = ^ArrayStore[int]{}
f3 := fiber deep_entry(list)
test.eq(f3.resume(), .suspended)
test.eq(list.len(), 0)
test.eq(f3.resume(), .done)
test.eq(list[0], 55)

-- The fiber's stack grows while it runs and after it was suspended deep in the stack.
fn grow_entry(list ^ArrayStore[int]):
    list << deep(3000)
    suspend
    list << deep(5000)
list = ^ArrayStore[int]{}
f4 := fiber grow_entry(list)
count := 0
while f4.resume() == .suspended:
    count += 1
test.eq(count, 3)
test.eq(list[0], 4501500)
test.eq(list[1], 12502500)

-- Managed locals and arguments of a suspended fiber are released when it runs to the end.
fn managed(prefix str, list ^ArrayStore[str]):
    local := prefix + '-local'
    suspend
    list << local
    suspend
    list << prefix
log = ^ArrayStore[str]{}
f5 := fiber managed('m', log)
while f5.resume() == .suspended:
    pass
test.eq(log.len(), 2)
test.eq(log[0], 'm-local')
test.eq(log[1], 'm')

-- A fiber can resume another fiber. `suspend` returns to the fiber that resumed it.
fn inner(log ^ArrayStore[str]):
    log << 'i1'
    suspend
    log << 'i2'
fn outer(log ^ArrayStore[str]):
    g := fiber inner(log)
    log << 'o1'
    test.eq(g.resume(), .suspended)
    suspend
    log << 'o2'
    test.eq(g.resume(), .done)
    log << 'o3'
log = ^ArrayStore[str]{}
f6 := fiber outer(log)
test.eq(f6.resume(), .suspended)
test.eq(log.len(), 2)
test.eq(f6.resume(), .done)
test.eq(log.len(), 5)
test.eq(log[0], 'o1')
test.eq(log[1], 'i1')
test.eq(log[2], 'o2')
test.eq(log[3], 'i2')
test.eq(log[4], 'o3')

-- A fiber that resumes another fiber is `.running` while the other one runs.
type StatusBox:
    status FiberStatus
fn probe(box ^StatusBox, other ^FiberBox):
    box.status = other.f.?.status()
type FiberBox:
    f ?Fiber
fn prober(box ^StatusBox, self_box ^FiberBox):
    p := fiber probe(box, self_box)
    test.eq(p.resume(), .done)
sbox := ^StatusBox{status=.done}
fbox := ^FiberBox{f=none}
fbox.f = fiber prober(sbox, fbox)
test.eq(fbox.f.?.resume(), .done)
test.eq(sbox.status, .running)
fbox.f = none

-- A generator is consumed inside a fiber. Its frame runs on the fiber's stack.
generator fn count_to(n int) -> int:
    for 0..n |i|:
        yield i
fn consume(list ^ArrayStore[int]):
    for count_to(3) |v|:
        list << v
        suspend
list = ^ArrayStore[int]{}
f7 := fiber consume(list)
count = 0
while f7.resume() == .suspended:
    count += 1
test.eq(count, 3)
test.eq(list.len(), 3)
test.eq(list[2], 2)

-- `suspend` in a generator body suspends the fiber that consumes the generator.
generator fn pausing(n int) -> int:
    for 0..n |i|:
        suspend
        yield i
fn consume2(list ^ArrayStore[int]):
    for pausing(2) |v|:
        list << v
list = ^ArrayStore[int]{}
f8 := fiber consume2(list)
test.eq(f8.resume(), .suspended)
test.eq(list.len(), 0)
test.eq(f8.resume(), .suspended)
test.eq(list.len(), 1)
test.eq(f8.resume(), .done)
test.eq(list.len(), 2)

-- A fiber with no arguments.
global hits int = 0
fn hit():
    hits += 1
    suspend
    hits += 1
f9 := fiber hit()
test.eq(f9.resume(), .suspended)
test.eq(hits, 1)
test.eq(f9.resume(), .done)
test.eq(hits, 2)

-- `suspend` outside of a fiber does nothing.
suspend
fn plain() -> int:
    suspend
    return 7
test.eq(plain(), 7)

-- `suspend` as a single line body.
fn spin(n int):
    for 0..n |i|: suspend
f10 := fiber spin(3)
count = 0
while f10.resume() == .suspended: count += 1
test.eq(count, 3)

-- `fiber` and `suspend` are keywords, `Fiber` is the type.
fn run_all(fa &Fiber, fb &Fiber):
    while true:
        alive := false
        if fa.resume() == .suspended:
            alive = true
        if fb.resume() == .suspended:
            alive = true
        if !alive:
            break
log = ^ArrayStore[str]{}
f11 := fiber worker('x', 2, log)
f12 := fiber worker('y', 1, log)
run_all(&f11, &f12)
test.eq(log.len(), 3)

-- `fiber:` with a body. The body is a closure over `^T` variables.
log = ^ArrayStore[str]{}
f13 := fiber:
    log << 'step 1'
    suspend
    log << 'step 2'
test.eq(f13.resume(), .suspended)
test.eq(log.len(), 1)
test.eq(f13.resume(), .done)
test.eq(log[1], 'step 2')

-- `fiber:` as a return value and with a single line body.
fn make(log ^ArrayStore[str]) -> Fiber:
    return fiber:
        log << 'made'
        suspend
f14 := make(log)
test.eq(f14.resume(), .suspended)
test.eq(f14.resume(), .done)
test.eq(log.len(), 3)
counter := ^0
f15 := fiber: counter.* += 1
test.eq(f15.resume(), .done)
test.eq(counter.*, 1)

-- A fiber that was never resumed can be destructed. Its arguments are released without the call.
type Res:
    id int
global res_dropped int = 0
global res_called int = 0
fn (&Res) @deinit():
    res_dropped += 1
fn hold(r Res, s str):
    res_called += 1
    suspend
fn never_started():
    f := fiber hold(Res{id=1}, 'abc' + 'def')
    test.eq(f.status(), .suspended)
never_started()
test.eq(res_dropped, 1)
test.eq(res_called, 0)
fn never_started_block():
    r := ^Res{id=2}
    f := fiber:
        res_called += r.id
    test.eq(f.status(), .suspended)
never_started_block()
test.eq(res_dropped, 2)
test.eq(res_called, 0)

-- A method is a fiber entry through its type. The receiver is the first argument.
type Job:
    n int
fn (^Job) work(by int):
    self.n += by
    suspend
    self.n += by
job := ^Job{n=0}
f16 := fiber Job.work(job, 2)
test.eq(f16.resume(), .suspended)
test.eq(job.n, 2)
test.eq(f16.resume(), .done)
test.eq(job.n, 4)

--cytest: pass
