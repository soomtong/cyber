k := 2
add_k := fn(n int) -> int => n + k
f := spawn add_k(3)

--cytest: error
--CompileError: A closure can not be the entry of `spawn`: what it captures stays with this thread. Pass the values as arguments of a function instead.
--
--@MainPath():3:12:
--f := spawn add_k(3)
--           ^~~~~
--
