use test

-- An option or a result is sent with the `@send` of its payload. The arguments and the result follow the same rule.
test.eq(5, spawn opt_len('hello').await())
test.eq(-1, spawn opt_len(none).await())
test.eq(3, spawn res_len('abc').await())
test.eq(-1, spawn res_len(error.Missing).await())

test.eq('w-2', spawn opt_word(2).await().?)
test.eq(true, spawn opt_word(-1).await() == none)
test.eq('w-3', spawn res_word(3).await()!)
test.eq(error.Neg, spawn res_word(-3).await().unwrap_error())

-- A struct with a `@send` inside an option.
test.eq('box7', spawn wrap(7).await().?.name)
test.eq(true, spawn wrap(-7).await() == none)
test.eq(9, spawn unwrap_box(Box{n = 9, name = 'b'}).await())
test.eq(0, spawn unwrap_box(none).await())

-- An option of an option.
test.eq('in', spawn nested('in').await().?.?)

-- A struct without references is sent as its bytes, like a result of the same type.
test.eq(3, spawn sum(Point{x = 1, y = 2}).await())
test.eq(7, spawn mk_point(3, 4).await().x + spawn mk_point(3, 4).await().y)

-- A dropped future of an option result frees the received string.
for 0..20 |i|:
    _ = spawn opt_word(i)

type Point:
    x int
    y int

fn sum(p Point) -> int:
    return p.x + p.y

fn mk_point(x int, y int) -> Point:
    return Point{x = x, y = y}

type Box:
    n    int
    name str

fn (&Box) @send(dst Thread) -> Box:
    return Box{n = self.n, name = self.name.@send(dst)}

fn opt_len(s ?str) -> int:
    if s |v|:
        return v.len()
    return -1

fn res_len(s !str) -> int:
    v := s !else:
        return -1
    return v.len()

fn opt_word(n int) -> ?str:
    if n < 0:
        return none
    return 'w-' + n.fmt()

fn res_word(n int) -> !str:
    if n < 0:
        return error.Neg
    return 'w-' + n.fmt()

fn wrap(n int) -> ?Box:
    if n < 0:
        return none
    return Box{n = n, name = 'box' + n.fmt()}

fn unwrap_box(b ?Box) -> int:
    if b |v|:
        return v.n
    return 0

fn nested(s str) -> ??str:
    return ?str(s)

--cytest: pass
