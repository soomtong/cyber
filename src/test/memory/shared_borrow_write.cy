use t 'test'

-- What a shared borrow still writes, and what an exclusive borrow is needed for.
type Node:
    xs []int

type Foo:
    n    int
    pos  int
    xs   []int
    node ^Node
    msg  str

-- A value that is not managed is written in place.
fn (&Foo) count():
    self.n += 1

fn bump(n &int):
    n.* += 1

-- What is behind a reference is reached through the reference.
fn (&Foo) grow_node():
    self.node.xs.append(1)
    self.node.xs = self.node.xs + {2}

fn (&&Foo) grow():
    self.xs.append(self.n)

fn (&&Foo) fail(pos int, msg str):
    self.pos = pos
    self.msg = msg

-- A plain value that is read from `self` is copied into the call.
fn (&&Foo) fail_here(msg str):
    self.fail(self.pos + 1, msg)

fn (&&Foo) set(i int, v int):
    self.xs[i] = v

fn fill(out &&[]str):
    out.* = {'a' + 'b'}
    out.append('c' + 'd')

-- A destructor has the only access to its value.
type Res:
    log  ^[]str
    name str

fn (&Res) @deinit():
    self.log.*.append(self.name)
    self.name = ''

f := Foo{n=1, pos=0, xs={}, node=^Node{xs={}}, msg=''}
f.count()
t.eq(2, f.n)
k := 1
bump(&k)
t.eq(2, k)
f.grow_node()
t.eq(2, f.node.xs.len())
f.grow()
f.set(0, 9)
t.eq(9, f.xs[0])
f.fail_here('x' + 'y')
t.eq(1, f.pos)
t.eq('xy', f.msg)

ss := []str{}
fill(&&ss)
t.eq(2, ss.len())
t.eq('cd', ss[1])

log := ^[]str{}
begin:
    r := Res{log=log, name='r' + '1'}
    t.eq('r1', r.name)
t.eq(1, log.len())
t.eq('r1', log[0])

--cytest: pass
