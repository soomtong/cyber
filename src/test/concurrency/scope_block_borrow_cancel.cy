use test

-- A fiber of a `scope` block holds a value that borrows from the block's frame, and is cancelled when its
-- sibling fails. The block is entered at many stack depths (`pad` and the size of each `body` frame), so for some
-- of them the parent's stack grows after `s.start` took the borrow and before the fiber runs. The value's
-- `@deinit` reads the borrow while the fiber is cancelled. A build that does not patch the borrows of the
-- suspended fibers (`Thread.patchFiberPtrs`) fails here.

global log int = 0

type View:
    r &int
fn (&View) @deinit():
    log += self.r.*

-- Starts, takes a view of the parent's value and waits.
fn holder(x &int, f Future[int]):
    v := View{r=x}
    _ = f.await()

fn fails() -> !void:
    return error.Fail

fn body0(f Future[int]) -> !void:
    var a [1]int = [1]int(0)
    x := 40 + a[0]
    scope |s|:
        s.start(holder, {&x, f})
        s.start(fails, {})

fn body1(f Future[int]) -> !void:
    var a [2]int = [2]int(0)
    x := 40 + a[0]
    scope |s|:
        s.start(holder, {&x, f})
        s.start(fails, {})

fn body2(f Future[int]) -> !void:
    var a [3]int = [3]int(0)
    x := 40 + a[0]
    scope |s|:
        s.start(holder, {&x, f})
        s.start(fails, {})

fn body3(f Future[int]) -> !void:
    var a [4]int = [4]int(0)
    x := 40 + a[0]
    scope |s|:
        s.start(holder, {&x, f})
        s.start(fails, {})

fn body4(f Future[int]) -> !void:
    var a [5]int = [5]int(0)
    x := 40 + a[0]
    scope |s|:
        s.start(holder, {&x, f})
        s.start(fails, {})

fn body5(f Future[int]) -> !void:
    var a [6]int = [6]int(0)
    x := 40 + a[0]
    scope |s|:
        s.start(holder, {&x, f})
        s.start(fails, {})

fn pad(n int, j int, f Future[int]) -> !void:
    if n == 0:
        if j == 0:
            return body0(f)
        else j == 1:
            return body1(f)
        else j == 2:
            return body2(f)
        else j == 3:
            return body3(f)
        else j == 4:
            return body4(f)
        else:
            return body5(f)
    return pad(n - 1, j, f)

fn run(n int, j int, f Future[int]):
    _ = pad(n, j, f)

bad := 0
for 0..60 |n|:
    for 0..6 |j|:
        r := FutureResolver.new(int)
        log = 0
        p := fiber run(n, j, r.future())
        while p.resume() != .done:
            pass
        if log != 40:
            bad += 1
test.eq(bad, 0)

--cytest: pass