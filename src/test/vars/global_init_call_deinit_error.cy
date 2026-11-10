type Res:
    x int

fn (&Res) @deinit():
    dropped += 1

fn make() -> int:
    r := Res{x=1}
    return r.x

global a int = make()
global dropped int = 0

--cytest: error
--CompileError: The initializer of `a` can reach `@deinit`, which accesses the global `dropped`. `dropped` is initialized after `a`.
--
--@MainPath():11:16:
--global a int = make()
--               ^~~~~~
--
