# Writing Cyber (guide for coding agents)

Cyber looks like Python: blocks are made by indentation, statements end at a newline, and `for`, `while`, `if`, `fn`, `use` and `print` feel almost the same. But Cyber is statically typed, has value ownership, and has no exceptions. Do not guess an unfamiliar construct from Python. Check the lists below first, then the manual.

This guide is built into the `cyber` executable, so it matches the version in the first line. Older Cyber syntax in your training data (`my`, `dyn`, `func`, `throw`, `catch`, `'$(x)'`, `#[generator] fn f()`, the symbol literal `@name`) is wrong. Write `generator fn f()` and `symbol.name`. If the guide and the compiler disagree, the compiler is right.

When Cyber runs inside another program (an embedding host), the host can load fewer modules, add its own modules, and run code without the `cyber` command. If the host's instructions differ from this guide about running code or about modules, follow the host.

## Running and checking code

- `cyber main.cy` compiles and runs a program. A compile error is reported before anything runs, with the file, line and column.
- `cyber fmt path...` rewrites files in one fixed style. `cyber fmt --check path...` writes nothing and exits with 1 when a file would change.
- `cyber doc <id>` prints a section of the manual. The ids are listed at the end of this guide.
- For tests, write `use test` and call `test.eq(expected, actual)`. A failed check ends the program with a panic and a non-zero exit code.
- When you are not sure that a construct or a method exists, run a small file first.

## Principles

- Write simple code where the types are visible. int, float, bool, str, []T, Map, ?T, !T and types with plain fields are enough.
- Use heap references `^T`, borrows `&T`, `move`, traits, templates, generators, fibers and `spawn` only when you must.
- A call that returns `!T` needs `!` before you print or use the value: `print(f()!)`, not `print(f())`.
- Declare every new variable with `:=` the first time, also inside loops and `if` blocks. `x = ...` only changes a variable that already exists.
- Call only the methods listed in "Methods that exist", or ones you have checked. Method names are snake_case.
- Most compile errors say how to fix the code. Do what the message says.

## Same as Python

- Indented blocks, the colon, `pass`, `break`, `continue`, `return`
- `and`, `or`, `not` with the same precedence as Python: `not a and b` is `(not a) and b`, and `not a == b` is `not (a == b)`
- `==`, `!=`, `<`, `<=`, `>`, `>=` for numbers and strings (strings compare by bytes), `+=`, `-=`, `*=`, `/=`
- Function calls `f(x)`, method calls `s.upper()`, indexing `xs[0]`, the idea of slicing `s[1..3]`
- Single and double quotes are the same for strings. Strings are immutable UTF-8.
- `[]T`, which you use like a list, shares its buffer on assignment (the same aliasing as a Python list)
- `max(a, b)` and `min(a, b)` for two values of the same type

## Differences from Python

Syntax. Each line is Python, then the Cyber form.

- `# comment` becomes `-- comment`
- `x = 1` (declare and assign are the same) becomes `x := 1` to declare and `x = 2` to reassign. `:=` again in the same block is an error.
- `def f(a, b):` becomes `fn f(a, b int) -> int:`. Parameter types and the return type are required. Group equal types as `a, b int`.
- `elif c:` becomes `else c:` (not `else if`)
- `for x in xs:` becomes `for xs |x|:`. With the index: `for xs |i, x|:` (the index comes first)
- `for x in ['a', 'b']:` becomes `for {'a', 'b'} |x|:`
- `for i in range(n):` becomes `for 0..n |i|:` (end excluded). `0..=n` includes the end. `n..>0` counts down.
- `f"{x}"` becomes `'%{x}'` interpolation. Expressions work: `'%{a + b}'`
- `x if c else y` becomes `if (c) x else y`. The parentheses around the condition are required.
- `a // b` becomes `a / b`. Integer division truncates toward zero. `//` is an error. Power `**` is the same.
- `import math` becomes `use math`. For a file: `use g 'geo.cy'`
- A function is declared only at the top level, not inside `if`, `for` or another function.
- `class P:` becomes `type P:` with fields such as `name str` below it. A method is `fn (&P) m():` and uses `self` inside. A method that changes the value is `fn (&&P) m():`. A `&P` method can write a number or bool field, but not a `str`, list or Map field: 'Cannot replace a managed value through a shared borrow.' or 'Cannot borrow exclusively through a shared borrow.' means that the method needs `&&P`.
- `P(name='a', n=1)` becomes `P{name='a', n=1}`. A field is set with `=`, not `:`.
- `print(a, b)` becomes `print(x)`. It takes exactly one argument. Join values with interpolation.
- `len(xs)` becomes `xs.len()`. It is a method. `xs.len` is an error.
- `xs.append(1)` stays `xs.append(1)` (or `xs += 1`). It changes `xs` in place and returns nothing.
- `x in xs` becomes `xs.contains(x)`, and for a Map `m.contains(k)`
- `[1, 2, 3]` becomes `{1, 2, 3}`. The list takes the type of its first element (`[]int`), and every other element must have that type. An empty list needs the type: `[]int{}`. You can always write the type: `[]str{'a', 'b'}`.
- `{"a": 1, "b": 2}` becomes `Map[str, int]{a=1, b=2}`. A bare name is a string key. Put an expression key in parentheses: `Map[str, int]{(k)=1}`. An empty Map is `Map[str, int]{}`.
- `(1, 2)` tuple becomes `type Pt(x, y float)` for a named tuple, or a struct
- `None` becomes `none`. Only inside a `?T` type.
- `assert` becomes `use test`, then `test.eq(expected, actual)`
- `if __name__ ...`: top-level statements are the program. Or declare `fn main()` (mixing the two is an error).

Semantics:

- Typing is static. A type error appears as a CompileError before a single line runs. A variable cannot change its type.
- There is no truthiness. The `x` in `if x:` must be a bool. Write `if xs.len() > 0:`. Bitwise operators are `&&`, `||` and `~`. Logic is `and`, `or` and `not`.
- Integers and floats are separate types. An arithmetic operator or a comparison with an int and a float converts the int, on either side, and gives a float: `i * f` is `f * i`. Two ints stay ints: `i / 2` is integer division, write `i / 2.0`. A float does not convert back: `i += f` and `var n int = i * f` are errors, write `int(i * f)`. A float always prints with a fraction: `5.0`, not `5`. Convert with `int(f)` to print `5`.
- A function cannot read a local variable of the outer scope. Pass it as a parameter, or declare a global with `global g int = 0`.
- Using a call that returns a value as a statement is an error. To discard the value, write `_ = f()`.
- A function that returns a value must return on every path. Otherwise: 'Missing return statement.'
- There are no default parameter values and no keyword arguments. Use overloading.
- `return` is not allowed at top level.
- A list literal without a type takes the type of its first element, and the other elements must have that type: `{1, 'a'}` and `{1.5, 2}` are errors. Write the type: `[]float{1.5, 2}`.
- A one-character string `'s'` becomes a code point (115) where an integer is expected, without an error: `[]int{1, 'a'}` is `{1, 97}`. If you doubt a variable's type, check it with `var n int = ...`.
- String indexing and `len()` count bytes. Use `s.count()` for the number of characters.
- A backslash in a string must be one of `\n`, `\t`, `\r`, `\0`, `\\`, `\'`, `\"` or `\xHH`. Any other (`\|`, `\d`, `\.` in a grep or regex pattern) is a compile error. Write the backslash twice: `'a\\|b'`.
- Map iteration follows hash order, not insertion order. If you need an order, copy the keys or entries into a list and sort it.
- A negative index `xs[-1]` panics. Use `xs.last()` or `xs[xs.len() - 1]` for the last element.
- A slice can omit its start or end: `s[..3]`, `s[2..]`. `s[1..3]` excludes the end and `s[1..=3]` includes it. Negative bounds are not allowed. Python's `s[:-1]` is `s[..s.len() - 1]` (`s[..-1]` panics).
- `xs[5]` out of range panics, and `m[k]` on a missing key panics. `m.get(k)` returns `?V`.
- Integer overflow wraps around. Division by zero panics.
- A number can contain the digit separator `_`: `1_000_000`, `0xff_ff`.
- `fiber`, `suspend` and `scope` are reserved words. Do not use them as variable or function names.

## Methods that exist

These are the common methods of the three types you use most. A Python method that is not here may not exist under its Python name. Look for the Cyber name under "Python name to Cyber name". Method names are snake_case: `starts_with`, not `startsWith`.

str (strings do not change; every method returns a new value):

- `s.len()` bytes, `s.count()` characters
- `s.contains(sub)`, `s.starts_with(p)`, `s.ends_with(p)`, `s.index(sub)` and `s.last_index(sub)` give `?int`
- `s.split(sep)` gives `[]str`, `s.replace(old, new)`, `s.upper()`, `s.lower()`, `s.repeat(n)`, `s.concat(t)`
- `s.trim()` cuts spaces, tabs and newlines at both ends. `s.trim({'-', '_'})` cuts the given characters.
- `s.trim_left()` and `s.trim_right()` cut only the start or only the end, by the same rule.
- `s.last()` the last byte
- `s.lines()` gives `[]str` split at `\n` or `\r\n`, without the line breaks and without an empty last line
- `s.pad_left(n)` and `s.pad_right(n)` add spaces until `s` has `n` characters. `s.pad_left(n, '0')` adds `'0'`.

[]T:

- `xs.len()`, `xs.contains(x)`, `xs.index(x)` gives `?int`, `xs.last()`
- `xs.join(sep)` for `[]str`, gives `str`
- `xs.append(x)`, `xs.insert(i, x)`, `xs.remove(i)`, `xs.clear()`, `xs.pop()` gives `?T`: each changes `xs` in place. `xs = xs.remove(0)` is a compile error
- `xs.appended(x)`, `xs.inserted(i, x)`, `xs.removed(i)`, `xs + x`: each gives a new list and leaves `xs` as it was
- The in-place methods also work on a global list (`global log []str = {}`, then `log.append(s)` in a function). An argument can not read the same global: `g.append(g.len())` is a compile error, so write `n := g.len()` first
- `xs.reverse()` reverses in place and returns nothing, like `xs.sort()`
- `xs.sort()` sorts in place in ascending order (numbers and strings). `xs.sort(|a, b| ...)` sorts by a function that returns true when `a` goes first. Both return nothing.

Map[K, V]:

- `m[k]` (panics when missing), `m.get(k)` gives `?V`, `m[k] = v`, `m.set(k, v)`
- `m.contains(k)`, `m.size()`, `m.keys()` gives `[]K`, `m.values()` gives `[]V` in the same order, `m.remove(k)`, `m.clear()`
- `for m |e|:` gives entries with `e.key` and `e.value`

Python name to Cyber name:

- `sep.join(xs)` is `xs.join(sep)` (the list joins, not the separator)
- `xs.find(x)` is `xs.index(x)`, which gives `?int`: `xs.index(x) ?else -1`
- `xs.pop()` is `xs.pop()`, but it gives `?T`: `v := xs.pop().?` when `xs` is not empty
- `s.startswith(p)` and `s.endswith(p)` are `s.starts_with(p)` and `s.ends_with(p)`
- `s.strip()` is `s.trim()`, `s.lstrip()` is `s.trim_left()` and `s.rstrip()` is `s.trim_right()`
- `s.find(sub)` is `s.index(sub)` and `s.rfind(sub)` is `s.last_index(sub)`. Both give `?int`. For the last part of a path use `path.base(p)`
- `os.path.join(a, b)` is `path.join(a, b)`, `os.path.basename(p)` is `path.base(p)`, `os.path.dirname(p)` is `path.dir(p)`, and `os.path.splitext(p)` is `path.stem(p)` with `path.ext(p)`. Add `use path`
- `len(m)` is `m.size()`. `m.items()` is `for m |e|:`. `list(m)` is `m.keys()`. `list(m.values())` is `m.values()`
- `s.splitlines()` is `s.lines()`. `s.rjust(n)` is `s.pad_left(n)`, `s.ljust(n)` is `s.pad_right(n)` and `s.zfill(n)` is `s.pad_left(n, '0')`
- `reversed(xs)` is `ys := []int{} + xs` then `ys.reverse()`. `ys := xs` shares the elements, and `ys.reverse()` or `ys.sort()` changes `xs` too
- `sorted(xs)` is `xs.sort()`, which changes `xs`. `sorted(xs, reverse=True)` is `xs.sort(|a, b| a > b)`

## Sorting

`xs.sort()` is ascending. For any other order give a function: `|a, b| a > b` for descending, `|a, b| a.n > b.n` for a field.

To sort by a value in a Map, the function must reach the Map. A lambda can use an outer variable only when it is declared with `^` (a heap reference) or is a borrow `&T`. Declare the Map with `^` from the start, and use it as a normal Map:

~~~cy
counts := ^Map[str, int]{}
for {'b', 'a', 'b'} |w|:
    counts[w] = (counts.get(w) ?else 0) + 1
names := counts.keys()
names.sort(|a, b| counts[a] > counts[b] or (counts[a] == counts[b] and a < b))
print(names.join(','))
~~~

When you need more than one value per item, copy the items into a list of structs and sort by a field, as in example 4.

## Missing features

list comprehensions, the `lambda` keyword (a lambda is written `|a, b| a + b` and only where the type is known), generator expressions, decorators, `with`, `try/except`, `raise`, inheritance, `*args`, `**kwargs`, `xs.map`, `xs.filter`, `abs`, `sum`, `sorted`, `enumerate`, `zip`, f-strings, the ternary `?:`, semicolons, `i++`.

## Modules

`core` is always loaded. Import the others with `use name`:

- `math`, `test`, `io`
- `os`: files, directories, environment, processes, `os.args()`. `cli` reads lines and runs the REPL.
  Text files: `os.read_file(p)!` returns `str`, `os.write_file(p, s)!`. Bytes: `os.read_file_bytes`, `os.write_file_bytes`.
  Programs: `os.cmd({'git', 'status'}).read()!` returns the stdout as `str`, `.run()!` lets the output through, and `.run_status()!` returns `out`, `err` and `code` without an error for a failed exit. Chain `.pipe(os.cmd({...}))`, `.dir(path)`, `.env(name, value)`, `.stdin(text)`, `.stdin_file(path)`, `.stdout_file(path)`, `.stderr_file(path)` and `.timeout_ms(ms)` before it. A command that runs past its limit is stopped with `error.TimedOut`. To read the output while a program runs, `p := cmd.start()!` then `while p.read_line()! |line|:`, and `p.wait()!` or `p.kill()` at the end. There is no shell: pass every argument as its own string, and use `pipe` instead of `|`. A failed exit is `error.ExitStatus`, a missing program `error.NotFound`.
- `json`, `toon`: parse and stringify, with a value tree.
- `regex`: a regular expression engine without backtracking (linear time). `peg`: parsing expression grammars.
- `time`: clocks, durations, dates and IANA time zones.
- `path`: path strings with `/`: `path.join(a, b)`, `path.base(p)`, `path.dir(p)`, `path.ext(p)` (`'.txt'`), `path.stem(p)`, `path.normalize(p)`, `path.is_absolute(p)`. It does not touch the file system.
- `meta`, `cy` (the Cyber parser), `c` and `libc` (FFI) are for advanced use.

An embedding host can refuse a module. Then `use name` fails with 'Failed to load module: name', 'Failed to resolve module `name`.' or a message from the host. Do not retry it; use what the host provides.

`cyber doc --api <module>` prints the functions and types of a module with their signatures. An embedding host may give them to you in another way. The manual sections `modules` and `ffi` describe how modules and FFI work.

## Errors and Option (instead of exceptions)

- A value that may be absent has type `?T`. To unwrap: `if x |v|:`, `x ?else default`, `x.?` (panics when absent).
- `?else` and `!else` take the whole rest of the expression as the default. Put them in parentheses inside a larger expression: `(h() ?else '') == 'server'`, `(f() !else 0) + 1`.
- An operation that may fail returns `!T`. A failure is `return error.Name`. The caller uses `f()!` (pass the failure to the caller; the enclosing function must return `!U`), `f() !else default`, or a `f() !else |e|:` block (the block must end with `return` or `panic`).
- `s.index(x)` gives `?int`. Test it with `if s.index(x) |i|:` (found at `i`) and `else:`, or with `if idx == none:`. `not idx`, `idx >= 0` and `idx!` are errors.
- `!` and `!else` work only on a `!T` value. On a `?T` (such as `s.index(x)`) use `?else`, `.?` or `if x |v|:`.
- To handle several calls together, use a `try:` block with `!` inside and receive the failure in `else |e|:`.
- `panic('msg')` cannot be caught. Use it for program bugs only. Return normal failures as `!T`.
- An error from `f()!` at the top level, or returned by `fn main() -> !T`, is an uncaught error and ends in a panic. To print a failure and go on, wrap the top-level code in a `try:` block and print it in `else |e|:` (a top-level `!else` block cannot end with `return`).
- A call that returns `!T` must be handled, even `!void`. A bare `os.write_file(p, s)` is an error. Write `os.write_file(p, s)!` inside `try:`, or `os.write_file(p, s) !else |e|:`.
- Unwrap a `!T` before you use the value: `x := r()!`, then `x.len()`. `print(r())` and `r().len()` are errors.
- `int('abc')` and `float('abc')` give 0 without an error. When you need validation, use `int.parse(s) !else ...` or `float.parse(s) !else ...`.
- The two rules meet on one letter: with `z := 'Z'`, `int(z)` parses the string and gives 0, but `int('Z')` takes the literal as the code point 90. To get the code of the first byte from a variable, use `int(z[0])`.

## Values, references, borrows

- Struct assignment copies. It is not shared like a Python object. `q := p; q.age = 9` does not change p.
- To share, lift the value to the heap with `^`: `p := ^P{name='a', age=3}`. Read and write fields as `p.age`, and use `p.*` for the whole value.
- An operator on a reference works on the value it points to only through `.*`: `n.* += 2`, `out.* += 'x'` for `out := ^[]str{}`.
- To let a function modify an argument, declare `fn inc(p &int)` and call `inc(&a)`.
- `Array[T]` cannot be copied. Passing or assigning a variable moves it (`total(a)`, `b := a`), and using the original after that is an error that names the move, until it is assigned again (`a = step(a)` is allowed, in a loop too). For an ordinary list use `[]T`.
- A closure can only capture variables of type `^T` or `&T`. In simple code use a plain function or a loop instead of a closure.
- In the REPL and in hosts that keep top-level variables between runs, a top-level borrow (`c := &x`) cannot be kept ('Cannot persist local ... of borrow type'). Borrow inside a function, or use `^T`.

## Examples

1. Declarations, interpolation, control flow

~~~cy
total := 0
for 1..=10 |i|:
    if i % 2 == 0:
        total += i
    else i == 7:
        total += 100
print('total=%{total}')
~~~

2. Functions and type conversion

~~~cy
fn mean(xs []int) -> float:
    sum := 0
    for xs |x|:
        sum += x
    return float(sum) / float(xs.len())

print(mean({1, 2, 3, 4}))
~~~

3. Building and sorting a list (append changes the list in place)

~~~cy
names := {'bob', 'alice'}
names += 'carol'
names.append('dave')
names.sort()
print(names.join(','))
~~~

4. Counting with a Map, then sorting the words by count (do not rely on hash order)

~~~cy
type WordCount:
    word str
    n int

counts := Map[str, int]{}
for 'the cat and the hat'.split(' ') |w|:
    counts[w] = (counts.get(w) ?else 0) + 1

rows := []WordCount{}
for counts |e|:
    rows += WordCount{word=e.key, n=e.value}
rows.sort(|a, b| a.n > b.n or (a.n == b.n and a.word < b.word))
for rows |r|:
    print('%{r.word}: %{r.n}')
~~~

5. Struct, methods, copy semantics

~~~cy
type Account:
    name str
    balance int = 0

fn (&&Account) deposit(n int):
    self.balance += n

fn (&Account) summary() -> str:
    return '%{self.name}: %{self.balance}'

a := Account{name='kim'}
a.deposit(50)
b := a
b.deposit(1)
print(a.summary())
print(b.summary())
~~~

6. Option

~~~cy
fn first_even(xs []int) -> ?int:
    for xs |x|:
        if x % 2 == 0:
            return x
    return none

if first_even({1, 4, 5}) |v|:
    print('found %{v}')
print(first_even({1, 3}) ?else -1)
~~~

7. Returning and handling an error

~~~cy
fn safe_div(a, b int) -> !int:
    if b == 0:
        return error.DivByZero
    return a / b

fn describe(a, b int) -> str:
    q := safe_div(a, b) !else |e|:
        return 'failed: %{e}'
    return 'ok: %{q}'

print(safe_div(9, 3) !else -1)
print(describe(9, 3))
print(describe(1, 0))
~~~

8. Error propagation and the try block

~~~cy
fn parse_sum(a, b str) -> !int:
    x := int.parse(a)!
    y := int.parse(b)!
    return x + y

try:
    n := parse_sum('4', '5')!
    print(n)
    m := parse_sum('4', 'x')!
    print(m)
else |e|:
    print('bad input: %{e}')
~~~

9. enum and switch (no else needed when every case is covered)

~~~cy
type Level enum:
    case low
    case high

fn label(l Level) -> str:
    switch l:
        case .low: return 'L'
        case .high: return 'H'

print(label(Level.high))
~~~

10. Shared reference and borrow

~~~cy
fn bump(n &int):
    n.* += 1

x := 1
bump(&x)

shared := ^x
alias := shared
alias.* = 10
print('%{x} %{shared.*}')
~~~

11. A test file

~~~cy
use test

fn clamp(x, lo, hi int) -> int:
    return max(lo, min(x, hi))

test.eq(5, clamp(5, 0, 10))
test.eq(0, clamp(-3, 0, 10))
test.eq(10, clamp(42, 0, 10))
~~~

## Errors whose message does not say the fix

Most compile errors say how to fix the code, for example 'Did you mean starts_with?', 'Write else cond:, not else if cond:', 'Unwrap it with ! first'. Follow those. The errors below do not, so the cause and the fix are given here. Each line is the first line of the error.

- 'Expected end of line or file. Got ...': `def`, `class`, `lambda x:`, a semicolon. Rewrite in Cyber syntax.
- 'Expected right operand.': `i++`, `10 // 3`, a `//` comment. Write `i += 1`, `/`, `--`.
- 'Expected `]`.': a list comprehension. Write a `for` loop that appends.
- 'Expected `,`.' in a function declaration: a default parameter value. Remove it and add an overload.
- 'Expected closing parenthesis.' in a call: a keyword argument `f(a=1)`. Pass it by position.
- 'Expected a target type or at least one element.': an empty `{}`. Write `[]int{}` or `Map[str, int]{}`.
- 'Expected type `bool`, got `int`.': a truthy condition. Use a comparison.
- 'Expected type `int`, got `float`.': a float is stored in an int (`i += f`, `var n int = i * 0.5`). An int and a float in one expression give a float. Convert the result with `int(...)`.
- 'Expected `int`, found `float`.': a float in a bitwise operator (`i && f`, `i << f`). Convert it with `int(f)`.
- 'Variable `x` is already declared in the block.': repeated `:=`. Write `x = ...`.
- 'Undeclared variable `x`.' inside a function: an outer local variable. Pass it as a parameter, or use `global`.
- 'Undeclared variable `abs`.' (also `sum`, `sorted`, `enumerate`, `zip`): a Python builtin. See "Missing features" and write a loop.
- 'Can not find the symbol `map` in `[]int`.' (also `filter`): write a loop.
- 'Expected `1` arguments, found `2`, when calling the function `fn print(...)`': write `print('%{a} %{b}')`.
- 'Can not find the symbol `&&` for `bool`.': logical AND. Write `and`.
- 'Cannot copy ..., type implements `NoCopy`.': copying an element of an Array (`x := a[0]`). Borrow it with `&a[0]`, or use `[]T`.
- 'Return statement is not allowed in the main block.': a top-level return. Wrap the code in `fn main():`.
- 'Missing return statement.': some path has no return. Add a return at the end.
- '`fn` declarations are not allowed here.': a function inside a block. Declare it at the top level.

Runtime panics: 'Out of bounds index: -1' is a negative index (use `xs.last()`), `OutOfBounds` on a slice is a negative or too large bound, and `MissingKey` is `m[k]` on a missing key (use `m.get(k)`).

An error raised inside a template can point to a line of a standard module (the module name and line, such as `core:196:5`) instead of your code. Check the call expression yourself.
