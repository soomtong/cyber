use t 'test'

-- A declaration with a false `#[cond]` is skipped. The next declaration of the same name is used.
#[cond=false]
fn pick() -> int:
    return 1

#[cond=true]
fn pick() -> int:
    return 2

t.eq(pick(), 2)

type A struct:
    x int

#[cond=false]
fn (&A) get() -> int:
    return -1

fn (&A) get(n int) -> int:
    return self.x + n

a := A{x=1}
t.eq(a.get(4), 5)

-- The condition of a template method can name the template parameters.
type R struct:
    with NoCopy
    id int

type Box[T Any] struct:
    x T

fn (&Box[]) one() -> int:
    return 1

#[cond=type.is_copyable(T)]
fn (&Box[]) dup() -> T:
    return self.x

#[cond=type.is_copyable(T)]
fn (&Box[]) sign(n int) -> int:
    return n

#[cond=!type.is_copyable(T)]
fn (&Box[]) sign(n int) -> int:
    return -n

b := Box[int]{x=3}
t.eq(b.dup(), 3)
t.eq(b.sign(5), 5)

r := Box[R]{x=R{id=7}}
t.eq(r.one(), 1)
t.eq(r.sign(5), -5)

--cytest: pass