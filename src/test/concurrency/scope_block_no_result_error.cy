fn work():
    suspend

fn run() -> int:
    scope |s|:
        s.start(work, {})
    return 1

--cytest: error
--CompileError: A `scope` block needs a function that returns `!T` or `error`, or an enclosing `try` block. An error of its fibers leaves the block like a failing `!`.
--
--@MainPath():5:5:
--    scope |s|:
--    ^~~~~~~~~~
--