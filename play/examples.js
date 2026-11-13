// The example programs of the playground. Each one runs on the WebAssembly build:
// it has no threads (`spawn`), no FFI and no file system.
const EXAMPLES = [
    {
        id: 'hello',
        title: 'Hello World',
        src: `use math

nouns := []str{'World', '世界', 'दुनिया', 'mundo'}
nouns += math.random().fmt()
for nouns |n|:
    print('Hello, %{n}!')
`,
    },
    {
        id: 'fibonacci',
        title: 'Fibonacci',
        src: `fn fib(n int) -> int:
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)

for 0..10 |i|:
    print('fib(%{i}) = %{fib(i)}')

print(fib(30))
`,
    },
    {
        id: 'types',
        title: 'Structs and choices',
        src: `type Vec2:
    x float
    y float

fn (&Vec2) len2() -> float:
    return self.x * self.x + self.y * self.y

type Shape enum:
    case circle float
    case rect   Vec2

fn area(s Shape) -> float:
    switch s:
        case .circle |r|:
            return 3.14159 * r * r
        case .rect |size|:
            return size.x * size.y

v := Vec2{x = 3, y = 4}
print(v.len2())
print(area(Shape.circle(2)))
print(area(Shape.rect(v)))
`,
    },
    {
        id: 'errors',
        title: 'Error handling',
        src: `fn parse_age(s str) -> !int:
    if s.len() == 0:
        return error.Empty
    age := int.parse(s)!
    if age < 0:
        return error.Negative
    return age

for []str{'42', '', '-3', 'abc'} |input|:
    try:
        age := parse_age(input)!
        print('age: %{age}')
    else |err|:
        print("'%{input}' -> %{err}")

-- A default for the error case.
print(parse_age('') !else 18)
`,
    },
    {
        id: 'generators',
        title: 'Generators',
        src: `generator fn fib_seq(limit int) -> int:
    a := 0
    b := 1
    while a < limit:
        yield a
        next := a + b
        a = b
        b = next

for fib_seq(100) |n|:
    print(n)

gen := fib_seq(10)
print(gen.status())
while gen.next() |n|:
    pass
print(gen.status())
`,
    },
    {
        id: 'fibers',
        title: 'Fibers',
        src: `fn worker(name str, steps int, log ^ArrayStore[str]):
    for 0..steps |i|:
        log << '%{name} step %{i}'
        -- Give the other fiber a turn.
        suspend

log := ^ArrayStore[str]{}
a := fiber worker('a', 3, log)
b := fiber worker('b', 2, log)

while a.status() != .done or b.status() != .done:
    _ = a.resume()
    _ = b.resume()

for log |line|:
    print(line)
`,
    },
    {
        id: 'scope',
        title: 'Structured concurrency',
        src: `fn add(out &int, n int) -> !void:
    suspend
    out.* += n

fn sum() -> !int:
    total := 0
    -- The block ends when every fiber is done, so the fibers can borrow \`total\`.
    scope |s|:
        s.start(add, {&total, 1})
        s.start(add, {&total, 2})
        s.start(add, {&total, 3})
    return total

fn slow(log ^ArrayStore[str]) -> !void:
    log << 'slow: start'
    suspend
    suspend
    log << 'slow: end'

fn fail() -> !void:
    suspend
    return error.Failed

fn group(log ^ArrayStore[str]) -> !void:
    scope |s|:
        s.start(slow, {log})
        s.start(fail, {})

print(sum()!)

-- A fiber that fails cancels the others. 'slow: end' is never logged.
log := ^ArrayStore[str]{}
try:
    group(log)!
else |err|:
    print(err)
for log |line|:
    print(line)
`,
    },
    {
        id: 'cancel',
        title: 'Cancelling a fiber',
        src: `type Conn:
    id int

fn (&Conn) @deinit():
    print('closed %{self.id}')

fn query(conn &Conn) -> int:
    suspend                -- Waiting for the reply.
    return 1

fn session(id int):
    conn := Conn{id = id}
    print('rows: %{query(&conn)}')

f := fiber session(7)
_ = f.resume()
-- The fiber returns from every call it is in. Its values are destructed.
print(f.cancel())
print(f.status())
`,
    },
];

if (typeof module !== 'undefined') {
    module.exports = { EXAMPLES };
}
