type J:
    n int

fn (&J) w() -> int:
    return self.n

j := J{n = 1}
x := spawn j.w()

--cytest: error
--CompileError: A thread entry cannot be a method call on a value. Pass the receiver as the first argument: `spawn T.w(obj)`.
--
--@MainPath():8:6:
--x := spawn j.w()
--     ^~~~~~~~~~~
--