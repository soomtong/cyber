type Res:
    name str
fn (&Res) @deinit():
    pass

type Pair:
    a Res
    b Res

p := Pair{a=Res{name='a'}, b=Res{name='b'}}
n := move p.a.name

--cytest: error
--CompileError: Cannot move a member out of `Res`. The type has a custom `@deinit`.
--
--@MainPath():11:11:
--n := move p.a.name
--          ^~~~~~~~
--
